export const id = "archived-uses-baseline";
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
