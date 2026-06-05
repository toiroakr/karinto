// Mirror package.json's version into moon.mod and version.mbt. Run after
// `changeset version` so the MoonBit manifest — and the `ENGINE_VERSION`
// constant the engine stamps into SARIF `tool.driver.version` — stay in
// lockstep with the changesets-managed version.
//
// moon.mod uses MoonBit's own manifest format (not plain JSON/TOML), so we
// rewrite the single `version = "..."` line textually to avoid depending on
// a parser for that format; version.mbt gets the same textual treatment.
import { readFileSync, writeFileSync } from "node:fs";

const TARGETS = [
  { file: "moon.mod", re: /^(version\s*=\s*)"([^"]*)"/m },
  { file: "version.mbt", re: /^(pub const ENGINE_VERSION\s*=\s*)"([^"]*)"/m },
];
const pkg = JSON.parse(readFileSync("package.json", "utf8"));

for (const { file, re } of TARGETS) {
  const text = readFileSync(file, "utf8");
  const match = text.match(re);
  if (!match) {
    console.error(`Could not find a version field in ${file}`);
    process.exit(1);
  }
  if (match[2] === pkg.version) {
    console.log(`${file} already at ${pkg.version}`);
    continue;
  }
  writeFileSync(file, text.replace(re, `$1"${pkg.version}"`));
  console.log(`${file} -> ${pkg.version}`);
}
