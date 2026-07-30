// scripts/lib/rebaseline-report.mjs
//
// The invalidated-rule report produced by scripts/rebaseline-captures.mjs:
// which ignore rules a bake-in kills, and what may safely be done about each.
//
// Split out from the CLI so it can be tested directly. Keeping it in the CLI
// would have meant guarding `main()` on whether the file was the entry point,
// and every form of that guard compares process.argv[1] against
// import.meta.url — which disagree whenever the script is reached through a
// symlink (argv keeps the link path, import.meta.url is realpath'd). The
// failure mode there is silent and severe: main() never runs, so a rebaseline
// job reports success having written nothing. No guard, no failure mode.
//
// See the "Which rules a rebaseline kills" section of
// scripts/rebaseline-captures.mjs for why attribution has to happen here at
// all, rather than in prune-diff-rules.yml.

import { computeDiff, matchRules, normalize } from "./replay-diff.mjs";

// ---------------------------------------------------------------------------
// Invalidated-rule attribution
// ---------------------------------------------------------------------------

// Ask which rules explain the diff that this capture's overwrite is about to
// destroy. Called with the PRE-write responses, so the answer is "what was this
// rule still doing for us", not "what is left afterwards" (afterwards the answer
// is always "nothing", which is exactly the ambiguity the header comment
// describes).
//
// Purely observational: it records counts and never influences whether the
// capture is written. `main` also wraps the whole attribution pass so that a
// failure here degrades the report to "unavailable" rather than aborting a
// bake-in half-way through the bucket — a partially rewritten baseline is the
// worst outcome this workflow can produce.
export function attributeInvalidatedRules(rules, cap, replayed, stats) {
  const diff = computeDiff(normalize(cap.response), normalize(replayed));
  // No diff the rules can see. This happens even for captures being rewritten:
  // the responses differ as JSON, but only in fields outside what computeDiff
  // compares (see its note). Nothing was being suppressed here, so nothing is
  // invalidated.
  if (diff.length === 0) return;

  stats.ruleVisible++;
  const { matched, threw } = matchRules(rules, cap, replayed, diff);
  for (const t of threw) {
    stats.threwByRule.set(t.rule.id, (stats.threwByRule.get(t.rule.id) || 0) + 1);
    console.error(`rule ${t.rule.id} threw during attribution: ${t.reason}`);
  }
  for (const r of matched) {
    stats.invalidatedByRule.set(r.id, (stats.invalidatedByRule.get(r.id) || 0) + 1);
  }
}

// Turn the raw counters into a per-rule verdict. Only rules that actually
// explained a destroyed diff appear — a rule that matched nothing was either
// not yet shipped or already dead, and this run has no evidence to tell those
// apart (see the header comment).
export function classifyInvalidated(attribution) {
  const out = [];
  for (const r of attribution.rules) {
    const invalidatedCount = attribution.invalidatedByRule.get(r.id) || 0;
    const threwCount = attribution.threwByRule.get(r.id) || 0;
    if (invalidatedCount === 0 && threwCount === 0) continue;
    let verdict;
    if (threwCount > 0) {
      verdict = "unattributable (matches() threw; repair the rule)";
    } else if (r.prunable === true) {
      verdict = attribution.partial
        ? "shipped, but --limit run — verify over the whole bucket before deleting"
        : "safe to delete";
    } else if (r.prunable === false) {
      verdict = "keep (permanent rule — the drift it masks will reopen)";
    } else {
      verdict = "keep (no `prunable` declaration — add one, see scripts/diff-rules/README.md)";
    }
    out.push({
      id: r.id,
      file: r.file,
      reason: r.reason,
      invalidatedCount,
      threwCount,
      prunable: r.prunable,
      deletable: threwCount === 0 && r.prunable === true && !attribution.partial,
      verdict,
    });
  }
  out.sort((a, b) => b.invalidatedCount - a.invalidatedCount);
  return out;
}

// ---------------------------------------------------------------------------
// Summary
// ---------------------------------------------------------------------------

export function buildSummary(summary) {
  const lines = [];
  lines.push("## Capture rebaseline");
  lines.push("");
  lines.push(`Replayed **${summary.replayed}** captures against \`${summary.target}\`.`);
  lines.push("");
  lines.push("| | count |");
  lines.push("|---|---|");
  lines.push(`| Rebaselined (response changed) | ${summary.rebaselined} |`);
  lines.push(`| Unchanged | ${summary.unchanged} |`);
  lines.push(`| Skipped (prod not ok) | ${summary.skipped} |`);
  if (summary.dryRun) {
    lines.push("");
    lines.push("> **Dry run** — no captures were written.");
  }

  const ruleRows = [...summary.ruleDeltas.entries()].sort((a, b) =>
    b[1].added + b[1].removed - (a[1].added + a[1].removed),
  );
  if (ruleRows.length) {
    lines.push("");
    lines.push("### Diagnostic deltas by rule");
    lines.push("");
    lines.push("| rule | added | removed |");
    lines.push("|---|---|---|");
    for (const [rule, d] of ruleRows) {
      lines.push(`| \`${rule}\` | ${d.added} | ${d.removed} |`);
    }
  }

  // The rules this run killed. Without this section the only trace is that some
  // rule quietly stops matching, which the pruner reads as "not shipped yet".
  const a = summary.attribution;
  lines.push("");
  lines.push("### Ignore rules invalidated by this rebaseline");
  lines.push("");
  if (!a.available) {
    lines.push(`Attribution unavailable: ${a.unavailableReason}`);
    lines.push("");
    lines.push("The rebaseline itself completed; only this report is missing.");
  } else {
    const invalidated = classifyInvalidated(a);
    if (invalidated.length === 0) {
      lines.push("None — no rule explained any diff this run baked in.");
    } else {
      lines.push("| rule | captures | prunable | verdict |");
      lines.push("|---|---|---|---|");
      for (const r of invalidated) {
        lines.push(
          `| \`${r.id}\` | ${r.invalidatedCount}${r.threwCount ? ` (+${r.threwCount} threw)` : ""} ` +
            `| ${r.prunable === null ? "_undeclared_" : `\`${r.prunable}\``} | ${r.verdict} |`,
        );
      }
      const deletable = invalidated.filter((r) => r.deletable);
      lines.push("");
      if (deletable.length > 0) {
        lines.push(
          `**${deletable.length} rule(s) are now dead** and can be deleted: ` +
            deletable.map((r) => `\`scripts/diff-rules/${r.file}\``).join(", ") + ".",
        );
        lines.push("");
        lines.push(
          "They each explained a real prod-vs-capture diff that this run has now " +
            "baked in, so they suppress nothing from here on. `prune-diff-rules.yml` " +
            "cannot find them on its own: it gates on `matchCount > 0` as proof the " +
            "fix shipped, and that evidence no longer exists.",
        );
      } else {
        lines.push("No rule is proposed for deletion — see the verdicts above.");
      }
    }
    if (a.partial) {
      lines.push("");
      lines.push(
        `> **Partial run** — \`--limit\` examined only ${summary.replayed} capture(s), ` +
          "so absence from this table does not prove a rule is dead elsewhere in the bucket.",
      );
    }
    // A skipped capture keeps its stale response, so its diff survives this run
    // and was never attributed. That cannot produce a bogus "safe to delete"
    // on its own — the verdict is earned from diffs actually destroyed — but a
    // rule listed here could still be carrying one of these, so say so.
    if (summary.skipped > 0) {
      lines.push("");
      lines.push(
        `> **${summary.skipped} capture(s) skipped** (prod did not return \`ok\`) and were ` +
          "left stale, so they were not examined. If a rule below is the only thing " +
          "explaining one of them, deleting it will resurface that diff — re-run once " +
          "prod is healthy to get a clean reading.",
      );
    }
  }

  if (summary.changed.length) {
    lines.push("");
    lines.push("<details><summary>Rebaselined captures</summary>");
    lines.push("");
    for (const c of summary.changed.slice(0, 50)) {
      lines.push(`- \`${c.hash.slice(0, 12)}\` — +${c.added} / -${c.removed} diagnostic(s)`);
    }
    if (summary.changed.length > 50) {
      lines.push(`- _…and ${summary.changed.length - 50} more_`);
    }
    lines.push("");
    lines.push("</details>");
  }
  return lines.join("\n") + "\n";
}

