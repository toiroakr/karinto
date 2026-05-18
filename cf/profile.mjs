// Profile breakdown — call lint_string repeatedly and use --cpu-prof later if needed.
// For now just check parse vs rules split using a YAML-only no-op via empty content.

import { lint_string } from "../_build/js/release/build/worker/worker.js";

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

const yaml = buildWorkflow(30, 15);
console.log(`size: ${yaml.length} bytes`);

// Run with all rules disabled via wildcard
const N = 5;
const ITERS = 100;
let bestAll = Infinity, bestNone = Infinity;
for (let trial = 0; trial < N; trial++) {
  const t0 = performance.now();
  for (let i = 0; i < ITERS; i++) lint_string(yaml, "", "");
  const t1 = performance.now();
  if (t1 - t0 < bestAll) bestAll = t1 - t0;

  const t2 = performance.now();
  for (let i = 0; i < ITERS; i++) lint_string(yaml, "", "*");
  const t3 = performance.now();
  if (t3 - t2 < bestNone) bestNone = t3 - t2;
}

console.log(`all rules:  ${(bestAll/ITERS).toFixed(3)} ms/call`);
console.log(`no rules:   ${(bestNone/ITERS).toFixed(3)} ms/call (yaml parse + prewalk only)`);
console.log(`rule cost:  ${((bestAll-bestNone)/ITERS).toFixed(3)} ms/call`);
