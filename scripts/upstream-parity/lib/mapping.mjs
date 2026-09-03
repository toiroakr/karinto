// Parses rules_catalog.mbt to build the upstream ↔ karinto rule mapping used
// by the parity check. Output shape:
//
//   {
//     karinto: { <id>: { id, source, origins: [...], status } },
//     bySource: {
//       actionlint: Map<upstreamId, karintoEntry>,
//       zizmor:     Map<upstreamId, karintoEntry>,
//       ghalint:    Map<upstreamId, karintoEntry>,   // keyed by both ghl-NNN and the parenthesised name
//     },
//   }
//
// rules_catalog.mbt is structured enough that a regex is more legible than
// pulling in a MoonBit parser. Each `spec(...)` block has 10 positional
// args; we only care about #0 (id), #2 (source enum), #3 (origins array),
// and #7 (status enum).

import { readFileSync } from "node:fs";

const SOURCES = new Set(["Actionlint", "Zizmor", "Ghalint", "Curllint"]);
const STATUSES = new Set(["Implemented", "Planned", "NotPlanned"]);

export function loadCatalog(catalogPath) {
  const src = readFileSync(catalogPath, "utf8");
  const entries = [];

  // Find each `spec(` call and consume up to its closing `)`.
  let i = 0;
  while (i < src.length) {
    const at = src.indexOf("spec(", i);
    if (at < 0) break;
    // Skip the spec() fn definition (it's introduced by `fn spec(`).
    const before = src.slice(Math.max(0, at - 8), at);
    if (/\bfn\s+$/.test(before)) {
      i = at + 5;
      continue;
    }
    const body = readBalanced(src, at + 5); // start after "spec("
    if (body == null) {
      i = at + 5;
      continue;
    }
    const parsed = parseSpec(body.text);
    if (parsed) entries.push(parsed);
    i = body.endIndex;
  }

  const karinto = {};
  const bySource = {
    actionlint: new Map(),
    zizmor: new Map(),
    ghalint: new Map(),
    curllint: new Map(),
  };

  for (const e of entries) {
    karinto[e.id] = e;
    for (const o of e.origins) {
      const parsed = parseOrigin(o);
      if (!parsed) continue;
      const bucket = bySource[parsed.source];
      if (!bucket) continue;
      bucket.set(parsed.upstreamId, e);
      for (const alias of parsed.aliases) bucket.set(alias, e);
    }
  }

  return { karinto, bySource, entries };
}

// Returns the substring inside the balanced parens starting at `start`
// (where src[start] is the character *after* the opening paren) and the
// index right after the matching closing paren.
function readBalanced(src, start) {
  let depth = 1;
  let i = start;
  let inString = false;
  while (i < src.length) {
    const ch = src[i];
    if (inString) {
      if (ch === "\\") {
        i += 2;
        continue;
      }
      if (ch === '"') inString = false;
      i++;
      continue;
    }
    if (ch === '"') {
      inString = true;
      i++;
      continue;
    }
    if (ch === "(") depth++;
    else if (ch === ")") {
      depth--;
      if (depth === 0) return { text: src.slice(start, i), endIndex: i + 1 };
    }
    i++;
  }
  return null;
}

function parseSpec(body) {
  // Split top-level commas (not inside [] or "").
  // Positional args of `spec(...)` in rules_catalog.mbt: id, title, source,
  // origins, category, default_severity, status, applies_to_workflow,
  // applies_to_action — 9 total. Keep this comment in sync with the `fn
  // spec(...)` signature; a drift here silently zeroes out the entire
  // catalog mapping (every upstream-fired rule reads back as "unmapped"),
  // which used to be invisible because `unmapped` didn't fail the check.
  const parts = splitTopLevel(body);
  if (parts.length < 9) return null;

  const idMatch = parts[0].match(/^\s*"([^"]+)"\s*$/);
  if (!idMatch) return null;
  const id = idMatch[1];

  const sourceTok = parts[2].trim();
  if (!SOURCES.has(sourceTok)) return null;
  const source = sourceTok.toLowerCase();

  const originsArr = parts[3].trim();
  if (!(originsArr.startsWith("[") && originsArr.endsWith("]"))) return null;
  const origins = [...originsArr.slice(1, -1).matchAll(/"([^"]+)"/g)].map(
    (m) => m[1],
  );

  const statusTok = parts[6].trim();
  if (!STATUSES.has(statusTok)) return null;

  return { id, source, origins, status: statusTok };
}

function splitTopLevel(s) {
  const parts = [];
  let depth = 0;
  let inString = false;
  let start = 0;
  for (let i = 0; i < s.length; i++) {
    const ch = s[i];
    if (inString) {
      if (ch === "\\") {
        i++;
        continue;
      }
      if (ch === '"') inString = false;
      continue;
    }
    if (ch === '"') {
      inString = true;
      continue;
    }
    if (ch === "[" || ch === "(" || ch === "{") depth++;
    else if (ch === "]" || ch === ")" || ch === "}") depth--;
    else if (ch === "," && depth === 0) {
      parts.push(s.slice(start, i));
      start = i + 1;
    }
  }
  parts.push(s.slice(start));
  return parts;
}

// Origin strings are one of:
//   "actionlint:unexpected-keys"
//   "zizmor:template-injection"
//   "ghalint:ghl-008 (action_ref_should_be_full_length_commit_sha)"
//   "curllint:something"
function parseOrigin(origin) {
  const colon = origin.indexOf(":");
  if (colon < 0) return null;
  const source = origin.slice(0, colon).trim().toLowerCase();
  const rest = origin.slice(colon + 1).trim();
  if (!rest) return null;
  // Pull off optional "(alias)" suffix.
  const m = rest.match(/^([^\s(]+)(?:\s*\(([^)]+)\))?\s*$/);
  if (!m) return { source, upstreamId: rest, aliases: [] };
  const upstreamId = m[1];
  const aliases = m[2] ? [m[2].trim()] : [];
  return { source, upstreamId, aliases };
}
