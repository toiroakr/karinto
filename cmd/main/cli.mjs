#!/usr/bin/env node
// Shell-rule-enabled CLI entry point (#113). `moon run --target js cmd/main`
// still works for everyday dev (see main.mbt's doc comment) but never
// awaits `shell-ts-adapter`'s async init, so the tree-sitter-bash shell
// rules (github-env / unpinned-tools / unredacted-secrets /
// use-trusted-publishing / shell-quote-safety / shell-undefined-var) stay
// dormant there — the adapter's readiness check reads false and those rules
// no-op safely, the same as they do under `moon test`.
//
// This wrapper awaits the adapter's init *before* the compiled entry point
// loads. It can't simply `import` that entry after the fact: the compiled
// output runs `main()` as a module-load side effect (a bare IIFE at the
// bottom of the emitted JS, not an exported function to call later), so the
// ordering has to be "await init, then dynamically `import()` the entry" —
// dynamic `import()` only starts evaluating its target when called, unlike
// a static `import`, which the JS module loader would hoist and run before
// this file's own top-level `await` had a chance to run.
//
//   moon build --target js --release
//   node cmd/main/cli.mjs -- .github/workflows/ci.yml
//
// Reads stdin / other args exactly like `moon run --target js cmd/main --`.
import { ensureInitNode } from "../../shell-ts-adapter/index.mjs";

await ensureInitNode();
await import("../../_build/js/release/build/cmd/main/main.js");
