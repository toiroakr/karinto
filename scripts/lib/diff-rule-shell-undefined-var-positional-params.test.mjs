// Focused tests for
// scripts/diff-rules/2026-10-shell-undefined-var-positional-params.mjs. Lives
// here (not next to the rule itself) because loadRules (replay-diff.mjs)
// treats every top-level .mjs file under scripts/diff-rules/ as a rule module
// and requires it to export `matches` — see that directory's README, "Every
// .mjs in this directory must be a rule". `--check-rules` only proves the
// module loads and exports the right shape (see scripts/replay.mjs); it never
// calls `matches()`, which is what this file covers.

import assert from "node:assert/strict";
import { test } from "node:test";

import { matches } from "../diff-rules/2026-10-shell-undefined-var-positional-params.mjs";

const undefinedVar = (name) => ({
  rule: "shell-undefined-var",
  severity: "info",
  message: `\`$${name}\` has no declared \`env:\` source and isn't assigned earlier in this script`,
});

function diagDiff(onlyInCaptured, onlyInReplayed = []) {
  return [{ kind: "diagnostics", onlyInCaptured, onlyInReplayed }];
}

test("matches: a removed shell-undefined-var finding for a positional parameter is accepted", () => {
  assert.equal(matches(null, null, diagDiff([undefinedVar("1")])), true);
});

test("matches: removed findings for $0 and a multi-digit parameter are accepted together", () => {
  const diff = diagDiff([undefinedVar("0"), undefinedVar("10")]);
  assert.equal(matches(null, null, diff), true);
});

test("matches: rejects a removed shell-undefined-var finding for a non-positional name", () => {
  assert.equal(matches(null, null, diagDiff([undefinedVar("FOO")])), false);
});

test("matches: rejects a positional removal mixed with a non-positional one", () => {
  const diff = diagDiff([undefinedVar("1"), undefinedVar("FOO")]);
  assert.equal(matches(null, null, diff), false);
});

test("matches: rejects a removed finding from a different rule", () => {
  const other = { rule: "shell-quote-safety", severity: "warning", message: "`$1` is unquoted" };
  assert.equal(matches(null, null, diagDiff([other])), false);
});

test("matches: rejects a replayed-only finding, even a positional shell-undefined-var one", () => {
  const diff = diagDiff([undefinedVar("1")], [undefinedVar("2")]);
  assert.equal(matches(null, null, diff), false);
});

test("matches: a metadata-kind diff entry is rejected outright", () => {
  const diff = [{ kind: "metadata", captured: {}, replayed: {} }];
  assert.equal(matches(null, null, diff), false);
});

test("matches: an ok-mismatch diff entry is rejected outright", () => {
  const diff = [{ kind: "ok-mismatch", captured: true, replayed: false }];
  assert.equal(matches(null, null, diff), false);
});

test("matches: an empty diff matches trivially", () => {
  assert.equal(matches(null, null, []), true);
});
