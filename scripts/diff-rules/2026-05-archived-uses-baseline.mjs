export const id = "archived-uses-baseline";
// Permanent, NOT prunable. The drift this rule masks comes from out-of-band KV
// state, not from a code change that a release can ship — so it matches against
// prod whenever the `archived:list` set has moved since capture time, and it
// will keep doing so forever. prune-diff-rules.yml must never delete it: a
// rebaseline would only clear the current drift, and the next refresh-archived
// run would reopen it with no rule left to suppress it.
export const prunable = false;
export const reason =
  "The `archived-uses` baseline lives in KV (key `archived:list`), maintained out-of-band by the refresh-archived CI job — it is NOT part of the normalized request, so the replay capture key ignores it. The KV set therefore differs between when prod captured a request and when the PR worker replays it, making `archived-uses` findings appear or disappear independently of any code change. This rule suppresses diffs whose every moving diagnostic is `archived-uses` (in either direction); any other rule difference still fails the replay.";

export function matches(_capture, _replayed, diff) {
  for (const d of diff) {
    if (d.kind !== "diagnostics") return false;
    if (!d.onlyInCaptured.every((x) => x.rule === "archived-uses")) return false;
    if (!d.onlyInReplayed.every((x) => x.rule === "archived-uses")) return false;
  }
  return true;
}
