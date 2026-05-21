// Benchmark harness — measures lint_string throughput on a synthetic workflow.
// Run: node bench.mjs [iters] [jobs] [steps_per_job]

import { lint_string } from "../_build/js/release/build/worker/worker.js";

const iters = Number(process.argv[2] || 200);
const numJobs = Number(process.argv[3] || 10);
const stepsPerJob = Number(process.argv[4] || 8);

function buildWorkflow(jobs, steps) {
  const lines = [
    "name: ci",
    "on: push",
    "permissions:",
    "  contents: read",
    "jobs:",
  ];
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

const yaml = buildWorkflow(numJobs, stepsPerJob);
console.log(`YAML size: ${yaml.length} bytes, ${yaml.split("\n").length} lines`);

// warmup
for (let i = 0; i < 20; i++) lint_string(yaml, "", "", "");

const N = 5;
const samples = [];
for (let trial = 0; trial < N; trial++) {
  const t0 = performance.now();
  for (let i = 0; i < iters; i++) {
    lint_string(yaml, "", "", "");
  }
  const t1 = performance.now();
  samples.push(t1 - t0);
}
samples.sort((a, b) => a - b);
const median = samples[Math.floor(N / 2)];
const best = samples[0];
const perCall = best / iters;
console.log(`iters=${iters} jobs=${numJobs} steps/job=${stepsPerJob}`);
console.log(`best: ${best.toFixed(2)} ms total, ${perCall.toFixed(3)} ms/call`);
console.log(`median: ${median.toFixed(2)} ms`);
console.log(`samples: ${samples.map((s) => s.toFixed(1)).join(", ")}`);
