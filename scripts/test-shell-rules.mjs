// End-to-end integration check for the tree-sitter-bash shell rules (#113):
// one real case per rule, run against the actual compiled Worker artifact
// with a real tree-sitter parse — the thing `moon test` structurally can't
// do (see the architecture note in shell_ts_ffi.mbt: moon's js-target test
// driver loads the compiled test bundle via CJS `require()`, which cannot
// load an ESM graph containing top-level await, so nothing can await the
// adapter's async init before a `test { }` body runs).
//
// The detection *logic* itself (github-env/unpinned-tools/unredacted-secrets/
// use-trusted-publishing/shell-quote-safety/shell-undefined-var) is
// thoroughly unit-tested under `moon test` against captured JSON-AST
// snapshots in `shell_rules_test.mbt` — this script only proves the seam
// (sanitize → real parse → JSON bridge → MoonBit AST → rule → diagnostic)
// actually works end to end.
//
// Usage: npm run test:shell-rules (builds the js target first)
//     or: moon build --target js --release && node scripts/test-shell-rules.mjs

import { ensureInitNode } from "../shell-ts-adapter/index.mjs";
import { lint_string } from "../_build/js/release/build/worker/worker.js";

await ensureInitNode();

const cases = [
  {
    rule: "github-env",
    yaml: `
on: pull_request_target
jobs:
  build:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    permissions:
      contents: read
    steps:
      - run: echo "TITLE=\${{ github.event.pull_request.title }}" >> $GITHUB_ENV
`,
  },
  {
    rule: "github-env",
    // The false negative the old per-line regex had: it never looked past
    // the `cat <<EOF >> "$GITHUB_ENV"` line itself.
    name: "github-env (heredoc)",
    yaml: `
on: pull_request_target
jobs:
  build:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    permissions:
      contents: read
    steps:
      - run: |
          cat <<EOF >> "$GITHUB_ENV"
          TITLE=\${{ github.event.pull_request.title }}
          EOF
`,
  },
  {
    rule: "unpinned-tools",
    yaml: `
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    permissions:
      contents: read
    steps:
      - run: curl -fsSL https://example.com/install.sh | bash
`,
  },
  {
    rule: "unpinned-tools",
    name: "unpinned-tools (curl piped to sudo bash — wrapper form)",
    yaml: `
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    permissions:
      contents: read
    steps:
      - run: curl -fsSL https://example.com/install.sh | sudo bash
`,
  },
  {
    rule: "unredacted-secrets",
    yaml: `
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    permissions:
      contents: read
    environment: prod
    steps:
      - run: |
          echo "\${{ secrets.TOKEN }}" | base64
`,
  },
  {
    rule: "use-trusted-publishing",
    yaml: `
on: push
jobs:
  publish:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    permissions:
      contents: read
    steps:
      - run: pnpm publish --no-git-checks
`,
    // Attributed to the offending step, not left job-only — this is what
    // lets an inline ignore comment on the step itself suppress it (see
    // zizmor_rules_test.mbt's ignore-comment tests, which still cover that
    // suppression behavior; this only re-adds the attribution assertion
    // that moved here from the old end-to-end test).
    checkAttribution: { job: "publish", stepIndex: 0 },
  },
  {
    rule: "use-trusted-publishing",
    name: "use-trusted-publishing (pnpm dlx pkg-pr-new is not a real publish)",
    yaml: `
on: push
jobs:
  preview:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    permissions:
      contents: read
    steps:
      - run: pnpm dlx pkg-pr-new@0.0.78 publish --compact
`,
    expectAbsent: true,
  },
  {
    rule: "shell-quote-safety",
    yaml: `
on: pull_request_target
jobs:
  build:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    permissions:
      contents: read
    steps:
      - env:
          TITLE: \${{ github.event.pull_request.title }}
        run: echo $TITLE
`,
  },
  {
    rule: "shell-undefined-var",
    yaml: `
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    permissions:
      contents: read
    steps:
      - run: echo $SOME_MYSTERY_VARIABLE
`,
  },
  {
    rule: "github-env",
    name: "github-env (step shell: pwsh — not bash, must not fire)",
    // Same shape as the "github-env" true-positive case above, but the
    // step declares `shell: pwsh`. `$env:GITHUB_ENV` in PowerShell isn't
    // bash/sh syntax tree-sitter-bash can parse; effective_shell/
    // is_bash_like_shell (rules.mbt) must skip it, not misparse it as bash.
    yaml: `
on: pull_request_target
jobs:
  build:
    runs-on: windows-latest
    timeout-minutes: 5
    permissions:
      contents: read
    steps:
      - shell: pwsh
        run: echo "TITLE=\${{ github.event.pull_request.title }}" >> $env:GITHUB_ENV
`,
    expectAbsent: true,
  },
  {
    rule: "shell-undefined-var",
    name: "shell-undefined-var (job defaults.run.shell: pwsh — not bash, must not fire)",
    yaml: `
on: push
jobs:
  build:
    runs-on: windows-latest
    timeout-minutes: 5
    permissions:
      contents: read
    defaults:
      run:
        shell: pwsh
    steps:
      - run: echo $SOME_MYSTERY_VARIABLE
`,
    expectAbsent: true,
  },
  {
    rule: "shell-undefined-var",
    name: "shell-undefined-var (runs-on as a label array on Windows — runner-default shell is still pwsh)",
    // `runs-on: [self-hosted, windows, x64]` — an array, not a scalar
    // string. effective_shell's windows-default fallback must still see
    // the "windows" label inside the array, not silently fall through to
    // the "bash" default just because runs-on isn't a plain string.
    yaml: `
on: push
jobs:
  build:
    runs-on: [self-hosted, windows, x64]
    timeout-minutes: 5
    permissions:
      contents: read
    steps:
      - run: echo $SOME_MYSTERY_VARIABLE
`,
    expectAbsent: true,
  },
  {
    rule: "shell-undefined-var",
    name: "shell-undefined-var (step shell: /bin/sh — still bash-family, must fire)",
    // is_bash_like_shell must recognize a full path to `sh`, not just the
    // bare literal "sh".
    yaml: `
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    permissions:
      contents: read
    steps:
      - shell: /bin/sh
        run: echo $SOME_MYSTERY_VARIABLE
`,
  },
];

let failures = 0;
for (const c of cases) {
  const label = c.name ?? c.rule;
  const result = JSON.parse(
    lint_string(c.yaml, "workflow", "", ""),
  ).result;
  const matches = result.diagnostics.filter((d) => d.rule === c.rule);
  const hit = matches.length > 0;
  let ok = c.expectAbsent ? !hit : hit;
  if (ok && !c.expectAbsent && c.checkAttribution) {
    const { job, stepIndex } = c.checkAttribution;
    ok = matches.some(
      (d) => d.job === job && d.step?.index === stepIndex,
    );
    if (!ok) {
      failures++;
      console.error(
        `FAIL ${label}: expected a ${c.rule} diagnostic attributed to job "${job}" step ${stepIndex}`,
      );
      console.error(JSON.stringify(matches, null, 2));
      continue;
    }
  }
  if (ok) {
    console.log(`ok   ${label}`);
  } else {
    failures++;
    console.error(`FAIL ${label}: expected ${c.rule} to ${c.expectAbsent ? "NOT " : ""}fire`);
    console.error(JSON.stringify(result.diagnostics, null, 2));
  }
}

if (failures > 0) {
  console.error(`\n${failures} of ${cases.length} case(s) failed`);
  process.exitCode = 1;
} else {
  console.log(`\nall ${cases.length} case(s) passed`);
}
