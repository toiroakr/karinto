// Hand-written (not MoonBit-generated) bridge to tree-sitter-bash, used by
// the shell-script rules (#113). Kept deliberately outside the MoonBit
// compiler's output so it can do the async WASM setup that karinto's
// synchronous `lint()` core can't: callers (the Worker's fetch handler, the
// CLI's entry wrapper, `scripts/test-shell-rules.mjs`) await one of the
// `ensureInit*` functions once before any lint call; `parseJson` and
// `isReady` are safe to call from MoonBit's sync `extern "js"` glue
// afterwards. `isReady()` staying false (never awaited, e.g. under `moon
// test --target js`, which never calls this module beyond importing it) is
// itself the target-agnostic story: the calling rule sees no AST and
// no-ops, the same as it does on native/wasm-gc where this module doesn't
// exist at all.
//
// No top-level await here: `moon test --target js` reaches this module via
// a static `#module` import compiled into every js build of the karinto
// package, whether or not a test actually exercises a shell rule. Node's
// `require()` (which is what moon's js test driver uses to load the
// compiled test bundle) cannot load an ESM graph that contains a
// top-level-await module — see the architecture notes in shell_ts_ffi.mbt.
import { Parser, Language } from "web-tree-sitter";

let parser = null;

function afterReady(Bash) {
  parser = new Parser();
  parser.setLanguage(Bash);
}

/**
 * Node path (CLI, `scripts/test-shell-rules.mjs`): both wasm blobs are
 * resolved as ordinary npm-package files and read with a plain path/URL,
 * exactly like `web-tree-sitter`'s own README examples — Node has no
 * restriction on compiling WASM from bytes at runtime.
 */
export async function ensureInitNode() {
  if (parser) return;
  // `import.meta.resolve` returns a `file://` string, not a `URL` object —
  // and Node's `fs` functions only special-case actual `URL` instances;
  // handed a string, they treat it as a literal (bogus) pathname instead of
  // parsing it, so this must be wrapped before it reaches `Language.load`'s
  // internal `fs.readFile(input)`.
  const bashWasmUrl = new URL(
    import.meta.resolve("tree-sitter-bash/tree-sitter-bash.wasm"),
  );
  await Parser.init();
  const Bash = await Language.load(bashWasmUrl);
  afterReady(Bash);
}

/**
 * Workers path: workerd forbids compiling WebAssembly from raw bytes at
 * runtime ("Wasm code generation disallowed by embedder" — verified against
 * real `wrangler dev`/workerd, not just Node). Both wasm blobs must already
 * be compiled `WebAssembly.Module` objects — wrangler's native `.wasm`
 * import produces exactly that at deploy/bundle time. `ttsModule` /
 * `bashModule` are those two imports, passed in by the caller (cf/index.js)
 * so this adapter has no bundler-specific import syntax of its own.
 */
export async function ensureInitWorkerd(ttsModule, bashModule) {
  if (parser) return;
  // web-tree-sitter's Emscripten glue branches into a real-Node code path
  // (`createRequire(import.meta.url)`) whenever `process.versions.node` is
  // truthy — which the `nodejs_compat` compatibility flag makes true even
  // under workerd, where `import.meta.url` is undefined in the bundled
  // module and the call throws. Hide `process` so the glue falls through to
  // its generic/non-Node branch instead — but only for the *synchronous*
  // call below, not the whole `await`: a Workers isolate can interleave
  // other in-flight requests across an `await`, and one of them observing
  // `process` as `undefined` here would be a confusing, unrelated bug.
  // `Parser.init` -> `initializeBinding` -> the Emscripten module factory
  // reads `process` at its very first line, before that factory's own
  // first internal `await` (which only happens inside the
  // `process`-gated branch we're steering it away from) — an async
  // function runs synchronously up to its first `await`/`return`, so by
  // the time the call expression below finishes evaluating (handing back a
  // pending promise), the read has already happened. Restoring `process`
  // immediately after, before awaiting that promise, closes the window to
  // zero: nothing can run between two synchronous statements.
  const savedProcess = globalThis.process;
  globalThis.process = undefined;
  let initPromise;
  try {
    initPromise = Parser.init({
      instantiateWasm(imports, successCallback) {
        const instance = new WebAssembly.Instance(ttsModule, imports);
        successCallback(instance, ttsModule);
        return instance.exports;
      },
    });
  } finally {
    globalThis.process = savedProcess;
  }
  await initPromise;
  // Requires the root patch-package patch (see patches/) adding a
  // `WebAssembly.Module` branch to `Language.load` — its public API only
  // natively accepts `Uint8Array` (raw bytes, forbidden here) or a
  // path/URL to `fetch`/`readFile` (neither meaningful for a bundled
  // Module import).
  const Bash = await Language.load(bashModule);
  afterReady(Bash);
}

export function isReady() {
  return parser !== null;
}

/** Parses `source` and returns a compact JSON AST (named nodes only). */
export function parseJson(source) {
  if (!parser) {
    throw new Error("shell-ts-adapter: ensureInit*() was not awaited");
  }
  const tree = parser.parse(source);
  const json = JSON.stringify(serialize(tree.rootNode));
  tree.delete();
  return json;
}

// Node types whose own text a shell_rules.mbt analyzer actually reads
// (grep `\.x\b` there before adding to this list). Every other node's text
// is a substring of some ancestor's, so omitting it keeps the bridged
// payload from growing roughly with tree depth on deeply nested scripts —
// `s`/`e` offsets (kept on every node) are enough for callers that only
// need to slice back into the original source, like
// `analyze_github_env`'s `${{ }}`-sanitization fallback.
const TEXT_NODE_TYPES = new Set([
  "command_name",
  "word",
  "variable_name",
  "file_redirect",
  "string",
  "string_content",
]);

function serialize(node) {
  const out = { t: node.type, s: node.startIndex, e: node.endIndex };
  if (TEXT_NODE_TYPES.has(node.type)) out.x = node.text;
  const children = node.namedChildren.filter(Boolean).map(serialize);
  if (children.length > 0) out.c = children;
  return out;
}
