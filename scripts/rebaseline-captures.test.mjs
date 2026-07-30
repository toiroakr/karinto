// Tests for the invalidated-rule attribution in rebaseline-captures.mjs.
// Run with `node --test scripts/`.
//
// Only 2026-05-archived-uses-baseline.mjs is left in scripts/diff-rules and the
// bucket is rebaselined, so a real run cannot produce a non-empty invalidated
// set. These synthetic rules exercise the path that a stale-capture run would.

import assert from "node:assert/strict";
import { test } from "node:test";

import {
  attributeInvalidatedRules,
  buildSummary,
  classifyInvalidated,
} from "./rebaseline-captures.mjs";

const diag = (rule, severity = "error", message = "m") => ({ rule, severity, message });
const capture = (diagnostics) => ({
  hash: "deadbeef",
  request: {},
  response: { ok: true, result: { kind: "workflow", stats: {}, diagnostics } },
});
const prodResponse = (diagnostics) => ({
  ok: true,
  result: { kind: "workflow", stats: {}, diagnostics },
});

const rule = (id, matches, prunable = true) => ({ id, file: `${id}.mjs`, reason: "", prunable, matches });

function freshStats(partial = false) {
  return {
    available: true,
    unavailableReason: null,
    partial,
    rules: [],
    invalidatedByRule: new Map(),
    threwByRule: new Map(),
    ruleVisible: 0,
  };
}

// ---------------------------------------------------------------------------
// attributeInvalidatedRules
// ---------------------------------------------------------------------------

test("attributes a rule that explains the diff about to be overwritten", () => {
  const stats = freshStats();
  // Capture carries a stale finding that prod no longer emits — the classic
  // "fix shipped, captures still old" state a rule exists to mask.
  const cap = capture([diag("stale-rule")]);
  const replayed = prodResponse([]);
  const rules = [rule("masks-stale", (c, r, diff) => diff.every((d) => d.kind === "diagnostics"))];
  stats.rules = rules;

  attributeInvalidatedRules(rules, cap, replayed, stats);

  assert.equal(stats.ruleVisible, 1);
  assert.equal(stats.invalidatedByRule.get("masks-stale"), 1);
  assert.equal(stats.threwByRule.size, 0);
});

test("counts every rule that explains the diff, not just the first", () => {
  const stats = freshStats();
  const rules = [rule("broad", () => true), rule("narrow", () => true)];
  stats.rules = rules;
  attributeInvalidatedRules(rules, capture([diag("x")]), prodResponse([]), stats);
  assert.equal(stats.invalidatedByRule.get("broad"), 1);
  assert.equal(stats.invalidatedByRule.get("narrow"), 1);
});

test("a rule that matches nothing is not attributed", () => {
  const stats = freshStats();
  const rules = [rule("unrelated", () => false)];
  stats.rules = rules;
  attributeInvalidatedRules(rules, capture([diag("x")]), prodResponse([]), stats);
  assert.equal(stats.ruleVisible, 1);
  assert.equal(stats.invalidatedByRule.size, 0);
});

// The key property: a rule whose fix has NOT shipped sees prod and captures
// agreeing, so there is no diff and it must not be reported as invalidated.
// This is what stops the report from proposing deletion of a rule that is about
// to become necessary.
test("no diff means nothing is invalidated, even with matching rules loaded", () => {
  const stats = freshStats();
  const rules = [rule("would-match-anything", () => true)];
  stats.rules = rules;
  const same = [diag("identical")];
  attributeInvalidatedRules(rules, capture(same), prodResponse(same), stats);
  assert.equal(stats.ruleVisible, 0);
  assert.equal(stats.invalidatedByRule.size, 0);
});

test("a throwing rule is recorded separately from a match", () => {
  const stats = freshStats();
  const rules = [
    rule("boom", () => {
      throw new Error("kaboom");
    }),
  ];
  stats.rules = rules;
  attributeInvalidatedRules(rules, capture([diag("x")]), prodResponse([]), stats);
  assert.equal(stats.invalidatedByRule.size, 0);
  assert.equal(stats.threwByRule.get("boom"), 1);
});

// ---------------------------------------------------------------------------
// classifyInvalidated
// ---------------------------------------------------------------------------

test("a shipped prunable rule on a full run is deletable", () => {
  const stats = freshStats();
  stats.rules = [rule("shipped", () => true, true)];
  stats.invalidatedByRule.set("shipped", 3);
  const [r] = classifyInvalidated(stats);
  assert.equal(r.id, "shipped");
  assert.equal(r.invalidatedCount, 3);
  assert.equal(r.deletable, true);
  assert.equal(r.verdict, "safe to delete");
});

test("a permanent rule is never deletable", () => {
  const stats = freshStats();
  stats.rules = [rule("permanent", () => true, false)];
  stats.invalidatedByRule.set("permanent", 5);
  const [r] = classifyInvalidated(stats);
  assert.equal(r.deletable, false);
  assert.match(r.verdict, /permanent/);
});

test("a rule with no prunable declaration is never deletable", () => {
  const stats = freshStats();
  stats.rules = [rule("undeclared", () => true, null)];
  stats.invalidatedByRule.set("undeclared", 2);
  const [r] = classifyInvalidated(stats);
  assert.equal(r.prunable, null);
  assert.equal(r.deletable, false);
  assert.match(r.verdict, /no `prunable` declaration/);
});

test("a rule that threw is unattributable even if it also matched", () => {
  const stats = freshStats();
  stats.rules = [rule("flaky", () => true, true)];
  stats.invalidatedByRule.set("flaky", 4);
  stats.threwByRule.set("flaky", 1);
  const [r] = classifyInvalidated(stats);
  assert.equal(r.deletable, false);
  assert.match(r.verdict, /threw/);
});

test("a --limit run never proposes deletion", () => {
  const stats = freshStats(true);
  stats.rules = [rule("shipped", () => true, true)];
  stats.invalidatedByRule.set("shipped", 3);
  const [r] = classifyInvalidated(stats);
  assert.equal(r.deletable, false);
  assert.match(r.verdict, /--limit/);
});

test("rules with no evidence either way are omitted entirely", () => {
  const stats = freshStats();
  stats.rules = [rule("silent", () => false, true), rule("hit", () => true, true)];
  stats.invalidatedByRule.set("hit", 1);
  const ids = classifyInvalidated(stats).map((r) => r.id);
  assert.deepEqual(ids, ["hit"]);
});

test("results are ordered by how many captures each rule explained", () => {
  const stats = freshStats();
  stats.rules = [rule("few", () => true), rule("many", () => true)];
  stats.invalidatedByRule.set("few", 1);
  stats.invalidatedByRule.set("many", 9);
  assert.deepEqual(classifyInvalidated(stats).map((r) => r.id), ["many", "few"]);
});

// ---------------------------------------------------------------------------
// buildSummary — the markdown that carries the report to a human
// ---------------------------------------------------------------------------

function summaryWith(attribution) {
  return {
    target: "https://example.invalid",
    dryRun: false,
    replayed: 10,
    rebaselined: 2,
    unchanged: 8,
    skipped: 0,
    ruleDeltas: new Map(),
    changed: [],
    attribution,
  };
}

test("summary names each dead rule file so the manual deletion is actionable", () => {
  const stats = freshStats();
  stats.rules = [rule("shipped", () => true, true)];
  stats.invalidatedByRule.set("shipped", 2);
  stats.ruleVisible = 2;
  const md = buildSummary(summaryWith(stats));
  assert.match(md, /Ignore rules invalidated by this rebaseline/);
  assert.match(md, /`shipped`/);
  assert.match(md, /scripts\/diff-rules\/shipped\.mjs/);
  assert.match(md, /1 rule\(s\) are now dead/);
});

test("summary proposes nothing when only a permanent rule was invalidated", () => {
  const stats = freshStats();
  stats.rules = [rule("permanent", () => true, false)];
  stats.invalidatedByRule.set("permanent", 3);
  const md = buildSummary(summaryWith(stats));
  assert.match(md, /No rule is proposed for deletion/);
  assert.doesNotMatch(md, /are now dead/);
});

test("summary reports the empty case rather than omitting the section", () => {
  const md = buildSummary(summaryWith(freshStats()));
  assert.match(md, /None — no rule explained any diff this run baked in/);
});

test("summary flags a partial run instead of implying full coverage", () => {
  const stats = freshStats(true);
  stats.rules = [rule("shipped", () => true, true)];
  stats.invalidatedByRule.set("shipped", 1);
  const md = buildSummary(summaryWith(stats));
  assert.match(md, /Partial run/);
  assert.doesNotMatch(md, /are now dead/);
});

test("summary warns that skipped captures were never examined", () => {
  const stats = freshStats();
  stats.rules = [rule("shipped", () => true, true)];
  stats.invalidatedByRule.set("shipped", 1);
  const s = summaryWith(stats);
  s.skipped = 4;
  const md = buildSummary(s);
  assert.match(md, /4 capture\(s\) skipped/);
  // The verdict still stands — it was earned from diffs actually destroyed —
  // but the caveat has to be visible next to it.
  assert.match(md, /are now dead/);
});

test("summary says attribution was unavailable without claiming the bake-in failed", () => {
  const stats = freshStats();
  stats.available = false;
  stats.unavailableReason = "broken import";
  const md = buildSummary(summaryWith(stats));
  assert.match(md, /Attribution unavailable: broken import/);
  assert.match(md, /rebaseline itself completed/);
});
