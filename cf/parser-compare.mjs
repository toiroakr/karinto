// Compare YAML parser cost: MoonBit @yaml vs js-yaml.
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

let yamlLib = null;
try {
  yamlLib = (await import("js-yaml")).default;
} catch {
  console.log("(js-yaml not installed)");
  process.exit(0);
}

const yaml = buildWorkflow(30, 15);
const ITERS = 500;
const N = 5;

// js-yaml parse
let bestJs = Infinity;
for (let t = 0; t < N; t++) {
  const t0 = performance.now();
  for (let i = 0; i < ITERS; i++) yamlLib.load(yaml);
  const t1 = performance.now();
  if (t1 - t0 < bestJs) bestJs = t1 - t0;
}

// MoonBit full lint (parse + rules + serialize)
let bestMb = Infinity;
for (let t = 0; t < N; t++) {
  const t0 = performance.now();
  for (let i = 0; i < ITERS; i++) lint_string(yaml, "", "");
  const t1 = performance.now();
  if (t1 - t0 < bestMb) bestMb = t1 - t0;
}

// MoonBit no-op (parse only via disable=*)
let bestMbNo = Infinity;
for (let t = 0; t < N; t++) {
  const t0 = performance.now();
  for (let i = 0; i < ITERS; i++) lint_string(yaml, "", "*");
  const t1 = performance.now();
  if (t1 - t0 < bestMbNo) bestMbNo = t1 - t0;
}

console.log(`large workflow ${yaml.length} bytes / ${yaml.split("\n").length} lines`);
console.log(`js-yaml parse:           ${(bestJs/ITERS).toFixed(3)} ms/call`);
console.log(`MoonBit parse+prewalk:   ${(bestMbNo/ITERS).toFixed(3)} ms/call`);
console.log(`MoonBit full lint:       ${(bestMb/ITERS).toFixed(3)} ms/call`);
console.log(`ratio: MoonBit/js-yaml = ${(bestMbNo/bestJs).toFixed(1)}x`);
