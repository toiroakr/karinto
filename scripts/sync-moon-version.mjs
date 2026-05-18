// Mirror package.json's version into moon.mod.json. Run after
// `changeset version` so the MoonBit manifest stays in lockstep with the
// changesets-managed version.
import { readFileSync, writeFileSync } from "node:fs";

const pkg = JSON.parse(readFileSync("package.json", "utf8"));
const moon = JSON.parse(readFileSync("moon.mod.json", "utf8"));

if (moon.version === pkg.version) {
  console.log(`moon.mod.json already at ${pkg.version}`);
  process.exit(0);
}

moon.version = pkg.version;
writeFileSync("moon.mod.json", JSON.stringify(moon, null, 2) + "\n");
console.log(`moon.mod.json -> ${pkg.version}`);
