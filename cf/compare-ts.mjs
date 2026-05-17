// Apples-to-apples: lint the same YAML via MoonBit and via the TS version.
//
// Setup (once):
//   git worktree add /tmp/curllint-ts origin/claude/github-actions-linter-worker-pkfwM
//   cd /tmp/curllint-ts && npm install
//   npx tsc -p . --outDir /tmp/curllint-ts-build --noEmit false \
//     --allowImportingTsExtensions false --rewriteRelativeImportExtensions
//   ln -sf /tmp/curllint-ts/node_modules /tmp/curllint-ts-build/src/node_modules
//
// Run: node compare-ts.mjs
import { lint_string } from "../_build/js/release/build/worker/worker.js";
import { lint as tsLint } from "/tmp/curllint-ts-build/src/linter.js";

function buildWorkflow(jobs, steps) {
  const lines = ["name: ci", "on: push", "permissions:", "  contents: read", "jobs:"];
  for (let j = 0; j < jobs; j++) {
    lines.push(`  job_${j}:`);
    lines.push(`    runs-on: ubuntu-latest`);
    lines.push(`    timeout-minutes: 10`);
    lines.push(`    permissions:`);
    lines.push(`      contents: read`);
    lines.push(`    steps:`);
    for (let s = 0; s < steps; s++) {
      if (s % 3 === 0) {
        lines.push(`      - uses: actions/checkout@aaaabbbbccccddddeeeeffff00001111222233334`);
        lines.push(`        with:`);
        lines.push(`          persist-credentials: false`);
      } else if (s % 3 === 1) {
        lines.push(`      - uses: actions/setup-node@v4`);
      } else {
        lines.push(`      - run: echo "step ${s}"`);
      }
    }
  }
  return lines.join("\n");
}

const sizes = [
  { label: "small  (3 jobs x 4 steps)",   yaml: buildWorkflow(3, 4) },
  { label: "medium (10 jobs x 8 steps)",  yaml: buildWorkflow(10, 8) },
  { label: "large  (30 jobs x 15 steps)", yaml: buildWorkflow(30, 15) },
];

const ITERS = 200;
const ROUNDS = 5;

function bench(fn) {
  let best = Infinity;
  for (let r = 0; r < ROUNDS; r++) {
    const t0 = performance.now();
    for (let i = 0; i < ITERS; i++) fn();
    const t1 = performance.now();
    if (t1 - t0 < best) best = t1 - t0;
  }
  return best / ITERS;
}

// Warm up
for (const { yaml } of sizes) {
  lint_string(yaml, "", "");
  tsLint(yaml);
}

console.log(`iters=${ITERS} rounds=${ROUNDS} (best of)`);
console.log();
console.log(`# Full lint (TS: 34 rules / MoonBit: 45 rules)`);
console.log(`${"size".padEnd(30)} ${"bytes".padStart(7)} ${"TS".padStart(10)} ${"MoonBit".padStart(10)}  speed-up`);
for (const { label, yaml } of sizes) {
  const ts = bench(() => tsLint(yaml));
  const mb = bench(() => lint_string(yaml, "", ""));
  const ratio = ts / mb;
  console.log(
    `${label.padEnd(30)} ${String(yaml.length).padStart(7)} ${(ts).toFixed(3).padStart(7)} ms  ${(mb).toFixed(3).padStart(7)} ms  ${ratio >= 1 ? "x" + ratio.toFixed(2) + " (MoonBit faster)" : "x" + (mb/ts).toFixed(2) + " (TS faster)"}`,
  );
}

console.log();
console.log(`# Parser only (disable=* — measures YAML parse + dispatch overhead)`);
console.log(`${"size".padEnd(30)} ${"bytes".padStart(7)} ${"TS".padStart(10)} ${"MoonBit".padStart(10)}  speed-up`);
for (const { label, yaml } of sizes) {
  // TS: all rules disabled via glob
  const ts = bench(() => tsLint(yaml, { disable: ["actionlint/*", "ghalint/*", "zizmor/*"] }));
  const mb = bench(() => lint_string(yaml, "", "*"));
  const ratio = ts / mb;
  console.log(
    `${label.padEnd(30)} ${String(yaml.length).padStart(7)} ${(ts).toFixed(3).padStart(7)} ms  ${(mb).toFixed(3).padStart(7)} ms  ${ratio >= 1 ? "x" + ratio.toFixed(2) + " (MoonBit faster)" : "x" + (mb/ts).toFixed(2) + " (TS faster)"}`,
  );
}

// Also compare diagnostic counts so we know the linters do similar work.
console.log();
console.log("diagnostic counts:");
for (const { label, yaml } of sizes) {
  const tsRes = tsLint(yaml);
  const mbRes = JSON.parse(lint_string(yaml, "", ""));
  console.log(
    `${label.padEnd(30)} TS=${tsRes.diagnostics.length}  MoonBit=${mbRes.result.diagnostics.length}`,
  );
}
