// Mirror package.json's version into moon.mod. Run after
// `changeset version` so the MoonBit manifest stays in lockstep with the
// changesets-managed version.
//
// moon.mod uses MoonBit's own manifest format (not plain JSON/TOML), so we
// rewrite the single `version = "..."` line textually to avoid depending on a
// parser for that format.
import { readFileSync, writeFileSync } from "node:fs";

const MANIFEST = "moon.mod";
const pkg = JSON.parse(readFileSync("package.json", "utf8"));
const text = readFileSync(MANIFEST, "utf8");

const match = text.match(/^version\s*=\s*"([^"]*)"/m);
if (!match) {
  console.error(`Could not find a version field in ${MANIFEST}`);
  process.exit(1);
}

if (match[1] === pkg.version) {
  console.log(`${MANIFEST} already at ${pkg.version}`);
  process.exit(0);
}

const updated = text.replace(/^(version\s*=\s*)"[^"]*"/m, `$1"${pkg.version}"`);
writeFileSync(MANIFEST, updated);
console.log(`${MANIFEST} -> ${pkg.version}`);
