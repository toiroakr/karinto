// Focused tests for scripts/diff-rules/2026-09-cache-mode-key.mjs. Lives here
// (not next to the rule itself) because loadRules (replay-diff.mjs) treats
// every top-level .mjs file under scripts/diff-rules/ as a rule module and
// requires it to export `matches` — see that directory's README, "Every
// .mjs in this directory must be a rule". `--check-rules` only proves the
// module loads and exports the right shape (see scripts/replay.mjs); it
// never calls `matches()`, which is what this file covers.

import assert from "node:assert/strict";
import { test } from "node:test";

import { matches } from "../diff-rules/2026-09-cache-mode-key.mjs";

const unexpectedKeys = (message = "job `release`: unknown key `cache-mode`") => ({
  rule: "unexpected-keys",
  severity: "error",
  message,
});

const invalidCacheMode = (message = "job `release`: `cache-mode` must be one of `read`/`write`/`write-only`/`none` (got `typo`)") => ({
  rule: "invalid-mapping-values",
  severity: "error",
  message,
});

function diagDiff(onlyInCaptured, onlyInReplayed = []) {
  return [{ kind: "diagnostics", onlyInCaptured, onlyInReplayed }];
}

test("matches: a valid cache-mode value just removes the unexpected-keys finding", () => {
  assert.equal(matches(null, null, diagDiff([unexpectedKeys()])), true);
});

test("matches: an out-of-enum value swaps unexpected-keys for invalid-mapping-values", () => {
  const diff = diagDiff([unexpectedKeys()], [invalidCacheMode()]);
  assert.equal(matches(null, null, diff), true);
});

test("matches: rejects an invalid-value finding with no corresponding unexpected-keys removal", () => {
  // Could happen with unexpected-keys disabled in the capture's config, or
  // be a genuinely new, unrelated invalid-mapping-values regression — either
  // way this rule can't attribute it to the cache-mode fix without the
  // removal on the other side.
  const diff = diagDiff([], [invalidCacheMode()]);
  assert.equal(matches(null, null, diff), false);
});

test("matches: rejects an unrelated captured-only finding", () => {
  const other = { rule: "some-other-rule", severity: "warning", message: "unrelated" };
  assert.equal(matches(null, null, diagDiff([other])), false);
});

test("matches: rejects an unrelated replayed-only finding", () => {
  const other = { rule: "some-other-rule", severity: "warning", message: "unrelated" };
  const diff = diagDiff([unexpectedKeys()], [other]);
  assert.equal(matches(null, null, diff), false);
});

test("matches: a metadata-kind diff entry is rejected outright", () => {
  const diff = [{ kind: "metadata", captured: {}, replayed: {} }];
  assert.equal(matches(null, null, diff), false);
});

test("matches: an empty diff matches trivially", () => {
  assert.equal(matches(null, null, []), true);
});
