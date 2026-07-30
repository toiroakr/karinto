// Tests for the diff/rule logic shared by replay.mjs and
// rebaseline-captures.mjs. Run with `node --test scripts/`.

import assert from "node:assert/strict";
import { test } from "node:test";

import { computeDiff, matchRules, normalize } from "./replay-diff.mjs";

function resp(diagnostics, extra = {}) {
  return { ok: true, result: { kind: "workflow", stats: {}, diagnostics }, ...extra };
}

const diag = (rule, severity = "error", message = "m") => ({ rule, severity, message });

// ---------------------------------------------------------------------------
// computeDiff
// ---------------------------------------------------------------------------

test("computeDiff: identical responses produce no entries", () => {
  const a = normalize(resp([diag("foo")]));
  const b = normalize(resp([diag("foo")]));
  assert.deepEqual(computeDiff(a, b), []);
});

test("computeDiff: diagnostic order does not matter", () => {
  const a = normalize(resp([diag("a"), diag("b")]));
  const b = normalize(resp([diag("b"), diag("a")]));
  assert.deepEqual(computeDiff(a, b), []);
});

test("computeDiff: added and removed diagnostics land on the right side", () => {
  const captured = normalize(resp([diag("gone")]));
  const replayed = normalize(resp([diag("new")]));
  const diff = computeDiff(captured, replayed);
  const entry = diff.find((d) => d.kind === "diagnostics");
  assert.ok(entry, "expected a diagnostics entry");
  assert.deepEqual(entry.onlyInCaptured.map((d) => d.rule), ["gone"]);
  assert.deepEqual(entry.onlyInReplayed.map((d) => d.rule), ["new"]);
});

test("computeDiff: duplicate diagnostics are compared by multiplicity", () => {
  const captured = normalize(resp([diag("dup"), diag("dup")]));
  const replayed = normalize(resp([diag("dup")]));
  const entry = computeDiff(captured, replayed).find((d) => d.kind === "diagnostics");
  assert.ok(entry, "a count difference must register as a diff");
  assert.equal(entry.onlyInCaptured.length, 1);
  assert.equal(entry.onlyInReplayed.length, 0);
});

test("computeDiff: ok mismatch is reported", () => {
  const captured = normalize({ ok: true, result: { diagnostics: [] } });
  const replayed = normalize({ ok: false, error: "boom" });
  const kinds = computeDiff(captured, replayed).map((d) => d.kind);
  assert.ok(kinds.includes("ok-mismatch"));
});

test("computeDiff: result metadata changes are caught outside diagnostics", () => {
  const captured = normalize({ ok: true, result: { kind: "workflow", stats: { n: 1 }, diagnostics: [] } });
  const replayed = normalize({ ok: true, result: { kind: "workflow", stats: { n: 2 }, diagnostics: [] } });
  const kinds = computeDiff(captured, replayed).map((d) => d.kind);
  assert.ok(kinds.includes("metadata"));
});

// This is the asymmetry rebaseline-captures.mjs depends on: diagnostics are
// compared on the (file, rule, severity, message) projection and the metadata
// pass strips `diagnostics`, so a change confined to some other diagnostic
// field is invisible here even though the raw JSON differs. Such a capture gets
// rewritten by the rebaseline but has no diff for any rule to have explained.
test("computeDiff: diagnostic fields outside the compared projection are invisible", () => {
  const captured = normalize(resp([{ ...diag("foo"), line: 1 }]));
  const replayed = normalize(resp([{ ...diag("foo"), line: 99 }]));
  assert.deepEqual(computeDiff(captured, replayed), []);
  assert.notEqual(JSON.stringify(captured), JSON.stringify(replayed));
});

// ---------------------------------------------------------------------------
// matchRules
// ---------------------------------------------------------------------------

const rule = (id, matches, prunable = true) => ({ id, file: `${id}.mjs`, reason: "", prunable, matches });

test("matchRules: returns every matching rule, not just the first", () => {
  const rules = [
    rule("broad", () => true),
    rule("narrow", () => true),
    rule("miss", () => false),
  ];
  const { matched, threw } = matchRules(rules, {}, {}, [{ kind: "diagnostics" }]);
  assert.deepEqual(matched.map((r) => r.id), ["broad", "narrow"]);
  assert.deepEqual(threw, []);
});

test("matchRules: preserves rule order so matched[0] is the suppressing rule", () => {
  const rules = [rule("first", () => false), rule("second", () => true), rule("third", () => true)];
  const { matched } = matchRules(rules, {}, {}, []);
  assert.equal(matched[0].id, "second");
});

test("matchRules: a throwing rule is isolated, not counted as a match", () => {
  const rules = [
    rule("boom", () => {
      throw new Error("kaboom");
    }),
    rule("ok", () => true),
  ];
  const { matched, threw } = matchRules(rules, {}, {}, []);
  assert.deepEqual(matched.map((r) => r.id), ["ok"]);
  assert.equal(threw.length, 1);
  assert.equal(threw[0].rule.id, "boom");
  assert.match(threw[0].reason, /kaboom/);
});

// A rule doing `throw null` must not make the catch block itself throw — that
// would kill the whole run instead of isolating one broken rule.
test("matchRules: a rule throwing a non-Error is still isolated", () => {
  const rules = [
    rule("nullthrow", () => {
      throw null;
    }),
  ];
  const { matched, threw } = matchRules(rules, {}, {}, []);
  assert.deepEqual(matched, []);
  assert.equal(threw.length, 1);
  assert.equal(threw[0].reason, "null");
});

test("matchRules: rules receive the capture, replayed response and diff", () => {
  const seen = [];
  const rules = [
    rule("spy", (cap, replayed, diff) => {
      seen.push({ cap, replayed, diff });
      return false;
    }),
  ];
  const cap = { hash: "abc" };
  const replayed = { ok: true };
  const diff = [{ kind: "metadata" }];
  matchRules(rules, cap, replayed, diff);
  assert.equal(seen.length, 1);
  assert.equal(seen[0].cap, cap);
  assert.equal(seen[0].replayed, replayed);
  assert.equal(seen[0].diff, diff);
});
