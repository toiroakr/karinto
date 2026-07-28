export const id = "dependabot-cooldown-implicit-default";
// Transient "shipped fix" rule — safe for prune-diff-rules.yml to remove once
// it matches against prod (prod serves the new behaviour, the captures are
// just stale).
export const prunable = true;
export const reason =
  "This PR follows zizmor 1.28.0's dependabot-cooldown changes (upstream #2193, GitHub's new implicit three-day default cooldown). Three things move: (a) the \"missing cooldown configuration\" and \"no default-days configured\" messages collapse into the single \"insufficient implicit default-days (less than 7)\" wording upstream now uses, (b) the pedantic-only \"multi-ecosystem-group cooldowns do not batch updates correctly\" finding is gone — zizmor 1.28.0 reports nothing for a multi-ecosystem group that configures a sufficient cooldown, and karinto firing it was the hard divergence that failed upstream-parity on this PR, and (c) every remaining arm of the audit is promoted from info to warning, mirroring upstream, so the otherwise-unchanged \"insufficient default-days configured (less than 7)\" finding also moves. Membership alone is too weak a test, so this rule additionally enforces the *shape* of the transition, counted per file: each captured info-severity finding whose entry configures no explicit default-days (either retired wording) must be answered by exactly one replayed warning-severity implicit finding, and each captured info-severity \"insufficient default-days configured\" must reappear as exactly one replayed warning of the same wording. Only the dropped multi-ecosystem-group finding is allowed to go unanswered, because upstream gives it no replacement. That makes the two regressions a membership-only test would hide — the new warning failing to appear at all, and a retired wording being remapped onto the wrong replacement — fail the rule instead of being suppressed. Any other rule, an info-severity finding appearing, a warning-severity finding disappearing, or a dependabot-cooldown message outside this set is likewise never suppressed. Self-expiring: delete once the change has shipped and prod captures roll over (~30 days post-release).";

// Wordings this PR retires in favour of the implicit one. Both described an
// `updates:` entry that configures no `default-days` of its own, so upstream
// now answers both with the same single finding.
const IMPLICIT_SOURCES = new Set([
  "missing cooldown configuration",
  "no default-days configured",
]);

// The pedantic finding upstream dropped outright. Unlike the two above it has
// no replacement, so it is the one captured-side finding allowed to go
// unanswered on the replayed side.
const DROPPED_MESSAGE =
  "multi-ecosystem-group cooldowns do not batch updates correctly";

// The single wording that replaces IMPLICIT_SOURCES.
const NEW_MESSAGE = "insufficient implicit default-days (less than 7)";

// Text-wise untouched, but it moves too because of the info → warning bump,
// so it shows up on both sides of the diff.
const UNCHANGED_MESSAGE = "insufficient default-days configured (less than 7)";

// Captures come from prod (the old behaviour), so every dependabot-cooldown
// finding on this side is info-severity. Returns the bucket the finding counts
// towards, or null if it is not part of the expected transition.
function classifyCaptured(x) {
  if (x.severity !== "info") return null;
  if (IMPLICIT_SOURCES.has(x.message)) return "implicit";
  if (x.message === UNCHANGED_MESSAGE) return "unchanged";
  if (x.message === DROPPED_MESSAGE) return "dropped";
  return null;
}

// The replayed side is this PR's worker, where every arm of the audit is a
// warning and the multi-ecosystem wording no longer exists.
function classifyReplayed(x) {
  if (x.severity !== "warning") return null;
  if (x.message === NEW_MESSAGE) return "implicit";
  if (x.message === UNCHANGED_MESSAGE) return "unchanged";
  return null;
}

// Diagnostics are compared as one flat multiset per capture and only carry
// `{file?, rule, severity, message}` — `file` is absent for single-result
// captures, hence the "" bucket. Counting per file rather than globally keeps
// a mismatch in one file from being cancelled out by an opposite mismatch in
// another. Returns null if any finding falls outside the expected transition.
function tally(entries, classify) {
  const byFile = new Map();
  for (const x of entries) {
    if (x.rule !== "dependabot-cooldown") return null;
    const bucket = classify(x);
    if (bucket === null) return null;
    const key = x.file || "";
    let counts = byFile.get(key);
    if (!counts) {
      counts = { implicit: 0, unchanged: 0, dropped: 0 };
      byFile.set(key, counts);
    }
    counts[bucket] += 1;
  }
  return byFile;
}

const EMPTY = { implicit: 0, unchanged: 0, dropped: 0 };

export function matches(_capture, _replayed, diff) {
  let sawArtifact = false;
  for (const d of diff) {
    if (d.kind !== "diagnostics") return false;

    const captured = tally(d.onlyInCaptured, classifyCaptured);
    const replayed = tally(d.onlyInReplayed, classifyReplayed);
    if (captured === null || replayed === null) return false;

    for (const file of new Set([...captured.keys(), ...replayed.keys()])) {
      const c = captured.get(file) || EMPTY;
      const r = replayed.get(file) || EMPTY;
      // Every entry that lost a "no explicit default-days" finding must have
      // gained exactly one implicit-wording finding, and every entry whose
      // explicit-default-days finding only changed severity must reappear with
      // the same wording. `dropped` is deliberately excluded: it is the one
      // finding upstream removed without a replacement.
      if (c.implicit !== r.implicit) return false;
      if (c.unchanged !== r.unchanged) return false;
    }

    if (d.onlyInCaptured.length > 0 || d.onlyInReplayed.length > 0) {
      sawArtifact = true;
    }
  }
  return sawArtifact;
}
