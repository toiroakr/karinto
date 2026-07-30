// scripts/lib/replay-diff.mjs
//
// Response comparison and ignore-rule evaluation shared by scripts/replay.mjs
// and scripts/rebaseline-captures.mjs.
//
// Both scripts must agree on what a "diff" is, because the rule contract
// `matches(capture, replayed, diff)` is written against the entry shapes
// produced here (see scripts/diff-rules/README.md). replay.mjs uses them to
// decide whether a diff is expected; rebaseline-captures.mjs uses them to work
// out which rules a bake-in is about to invalidate. Two independent
// implementations would drift, and the failure would be silent: a rule would
// simply stop matching on one side, which reads as "the fix has not shipped"
// rather than as a bug.

import { readdir } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));

// Single source of truth for where the ignore rules live, so the two callers
// cannot disagree about it.
export const RULES_DIR = join(__dirname, "..", "diff-rules");

// ---------------------------------------------------------------------------
// Normalization
// ---------------------------------------------------------------------------

export function sortDiagnostics(diags) {
  return [...diags].sort((a, b) => {
    const ra = a.rule || "";
    const rb = b.rule || "";
    if (ra !== rb) return ra < rb ? -1 : 1;
    const sa = a.severity || "";
    const sb = b.severity || "";
    if (sa !== sb) return sa < sb ? -1 : 1;
    const ma = a.message || "";
    const mb = b.message || "";
    if (ma !== mb) return ma < mb ? -1 : 1;
    return 0;
  });
}

export function normalize(resp) {
  if (!resp || typeof resp !== "object") return resp;
  const out = { ok: !!resp.ok };
  if (resp.error) out.error = resp.error;
  if (resp.result) {
    out.result = {
      kind: resp.result.kind,
      stats: resp.result.stats,
      diagnostics: sortDiagnostics(resp.result.diagnostics || []),
    };
  }
  if (Array.isArray(resp.files)) {
    out.files = resp.files.map((f) => ({
      path: f.path,
      ok: f.ok,
      error: f.error,
      result: f.result
        ? {
            kind: f.result.kind,
            stats: f.result.stats,
            diagnostics: sortDiagnostics(f.result.diagnostics || []),
          }
        : undefined,
    }));
  }
  return out;
}

// Stable stringify for metadata diff comparison. The main purpose is to sort
// object keys so insertion order doesn't show up as a diff. Inside objects we
// drop `undefined` values (matching JSON.stringify) so `{a:1, b:undefined}`
// canonicalizes identically to `{a:1}`. Inside arrays — and at the top level —
// we emit `"null"` instead of JSON.stringify's literal `undefined`/`null`
// asymmetry, so any pair of inputs always produces a comparable string.
export function canonicalJson(value) {
  if (value === undefined) return "null";
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) {
    return "[" + value.map(canonicalJson).join(",") + "]";
  }
  const parts = [];
  for (const k of Object.keys(value).sort()) {
    const v = value[k];
    if (v === undefined) continue;
    parts.push(JSON.stringify(k) + ":" + canonicalJson(v));
  }
  return "{" + parts.join(",") + "}";
}

export function stripDiagnostics(resp) {
  if (!resp || typeof resp !== "object") return resp;
  const out = { ...resp };
  if (out.result) {
    const { diagnostics: _d, ...rest } = out.result;
    out.result = rest;
  }
  if (Array.isArray(out.files)) {
    out.files = out.files.map((f) => {
      if (!f.result) return f;
      const { diagnostics: _d, ...rest } = f.result;
      return { ...f, result: rest };
    });
  }
  return out;
}

// ---------------------------------------------------------------------------
// Diagnostics
// ---------------------------------------------------------------------------

export function collectDiagnostics(resp) {
  if (resp.result?.diagnostics) {
    return resp.result.diagnostics.map((d) => ({
      rule: d.rule,
      severity: d.severity,
      message: d.message,
    }));
  }
  if (Array.isArray(resp.files)) {
    const out = [];
    for (const f of resp.files) {
      for (const d of f.result?.diagnostics || []) {
        out.push({
          file: f.path,
          rule: d.rule,
          severity: d.severity,
          message: d.message,
        });
      }
    }
    return out;
  }
  return [];
}

export function diagKey(d) {
  return JSON.stringify([d.file || "", d.rule, d.severity, d.message]);
}

export function multisetSubtract(left, right) {
  const counts = new Map();
  for (const item of right) {
    const k = diagKey(item);
    counts.set(k, (counts.get(k) || 0) + 1);
  }
  const out = [];
  for (const item of left) {
    const k = diagKey(item);
    const c = counts.get(k) || 0;
    if (c > 0) counts.set(k, c - 1);
    else out.push(item);
  }
  return out;
}

// ---------------------------------------------------------------------------
// Diff
// ---------------------------------------------------------------------------

// Both arguments must already be `normalize()`d. Returns the diff entries the
// rule contract is written against; an empty array means the two responses are
// equivalent as far as the rules can see.
//
// Note this is deliberately coarser than raw response equality: diagnostics are
// compared on the (file, rule, severity, message) projection, and the metadata
// pass strips `diagnostics` entirely. So two responses whose diagnostics differ
// only in fields outside that projection produce NO diff entries here even
// though their JSON differs. rebaseline-captures.mjs relies on this distinction
// — see the comment on its rule-visible diff counter.
export function computeDiff(captured, replayed) {
  const diffs = [];
  if (captured.ok !== replayed.ok) {
    diffs.push({ kind: "ok-mismatch", captured: captured.ok, replayed: replayed.ok });
  }

  // Diagnostic comparison uses count maps so a duplicate diagnostic
  // appearing N times in one side and M times in the other is treated as
  // a real diff (Set-based comparison would collapse multiplicity).
  const cap = collectDiagnostics(captured);
  const rep = collectDiagnostics(replayed);
  const onlyInCaptured = multisetSubtract(cap, rep);
  const onlyInReplayed = multisetSubtract(rep, cap);
  if (onlyInCaptured.length || onlyInReplayed.length) {
    diffs.push({ kind: "diagnostics", onlyInCaptured, onlyInReplayed });
  }

  // Catch-all for everything else `normalize()` exposes — result.kind,
  // result.stats, per-file ok/error, parse-error details, etc. Without this
  // a PR could regress documented response metadata without failing here.
  const capMeta = stripDiagnostics(captured);
  const repMeta = stripDiagnostics(replayed);
  // Use a canonical stringify (sorted object keys) so a different insertion
  // order between prod and PR does not register as a metadata diff — we only
  // want to flag semantic differences.
  if (canonicalJson(capMeta) !== canonicalJson(repMeta)) {
    diffs.push({ kind: "metadata", captured: capMeta, replayed: repMeta });
  }
  return diffs;
}

// ---------------------------------------------------------------------------
// Rules
// ---------------------------------------------------------------------------

// Returns { rules, skipped }. `skipped` lists .mjs files that imported cleanly
// but export no `matches` function. Every .mjs in this directory is supposed to
// be a rule (see the README), so a skipped file is a rule that silently does
// nothing: its intended diff resurfaces as "unexpected", which fails replay on
// every PR and — via the pruner's unexpected == 0 gate — blocks pruning too.
// Callers surface it rather than letting it pass as "no rules to apply".
export async function loadRules(dir = RULES_DIR) {
  let entries;
  try {
    entries = await readdir(dir);
  } catch {
    return { rules: [], skipped: [] };
  }
  const rules = [];
  const skipped = [];
  for (const f of entries.sort()) {
    if (!f.endsWith(".mjs")) continue;
    let mod;
    try {
      mod = await import(pathToFileURL(join(dir, f)).href);
    } catch (e) {
      const reason = e instanceof Error ? e.message : String(e);
      throw new Error(
        `scripts/diff-rules/${f} failed to load (broken import? a delegate rule file may have been pruned out from under it): ${reason}`,
        { cause: e },
      );
    }
    if (typeof mod.matches !== "function") {
      skipped.push(f);
      continue;
    }
    rules.push({
      id: mod.id || f.replace(/\.mjs$/, ""),
      file: f,
      reason: mod.reason || "",
      // Prunability declaration, consumed by prune-diff-rules.yml and by
      // rebaseline-captures.mjs's invalidated-rule report:
      //   true  — transient "shipped fix" rule. Once prod serves the new
      //           behaviour the rule only masks stale captures, so the pruner
      //           may open a PR deleting it.
      //   false — permanent rule masking drift that no code change causes
      //           (e.g. the out-of-band `archived:list` KV set). It matches
      //           against prod indefinitely and must never be pruned.
      //   null  — undeclared. Treated as unprunable; the pruner warns so the
      //           omission is visible instead of silently disabling pruning.
      prunable: typeof mod.prunable === "boolean" ? mod.prunable : null,
      matches: mod.matches,
    });
  }
  return { rules, skipped };
}

// Evaluate EVERY rule against one diff rather than stopping at the first match,
// and isolate throws.
//
// All-rules evaluation matters for attribution: rules are tried in filename
// (date) order, so if an older, broader rule absorbed a newer one's captures,
// the newer rule would report zero matches and both the pruner and the
// rebaseline's invalidated-rule report would wrongly conclude its fix has not
// shipped — leaving a stale rule masking real regressions indefinitely.
//
// Returns matched rule objects (in rule order, so `matched[0]` is the one
// replay credits with suppression) and, separately, the rules that threw. A
// rule that throws suppresses nothing, so neither its match count nor its
// silence says anything about whether its fix shipped; callers must keep the
// two apart instead of folding a throw into "did not match".
export function matchRules(rules, capture, replayed, diff) {
  const matched = [];
  const threw = [];
  for (const r of rules) {
    let isMatch = false;
    try {
      isMatch = r.matches(capture, replayed, diff);
    } catch (e) {
      // `String(e)` rather than `e.message`: a rule that throws a non-Error
      // (`throw null`) would otherwise make this catch block itself throw,
      // killing the whole run instead of isolating the broken rule.
      threw.push({ rule: r, reason: e instanceof Error ? e.message : String(e) });
      continue;
    }
    if (isMatch) matched.push(r);
  }
  return { matched, threw };
}
