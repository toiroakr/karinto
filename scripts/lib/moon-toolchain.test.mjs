import assert from "node:assert/strict";
import { chmodSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

const root = fileURLToPath(new URL("../../", import.meta.url));

test("every MoonBit workflow installs the shared pinned toolchain", () => {
  const workflows = readdirSync(`${root}.github/workflows`).filter((file) => /\.ya?ml$/.test(file));
  let installers = 0;
  for (const file of workflows) {
    const source = readFileSync(`${root}.github/workflows/${file}`, "utf8");
    assert.doesNotMatch(source, /cli\.moonbitlang\.com\/install\//, `${file} bypasses the shared toolchain pin`);
    if (/\brun:.*\bmoon\b|\n\s+moon\s/.test(source)) {
      assert.match(source, /run: bash scripts\/install-moon\.sh/, `${file} must install the pinned toolchain`);
      installers++;
    }
  }
  assert.ok(installers >= 6, "expected all build, test, release and agent workflows");
});

test("installer passes the exact pin and reports the installed toolchain", () => {
  const dir = mkdtempSync(join(tmpdir(), "karinto-moon-"));
  try {
    mkdirSync(`${dir}/scripts`);
    mkdirSync(`${dir}/bin`);
    mkdirSync(`${dir}/moon/bin`, { recursive: true });
    writeFileSync(`${dir}/scripts/install-moon.sh`, readFileSync(`${root}scripts/install-moon.sh`));
    writeFileSync(`${dir}/.moonbit-version`, "0.10.13+cbb11c36f\n");
    writeFileSync(`${dir}/bin/curl`, '#!/bin/sh\ncat <<\'INSTALLER\'\nprintf "%s\\n" "$@" > "$PIN_LOG"\nINSTALLER\n');
    writeFileSync(`${dir}/moon/bin/moon`, '#!/bin/sh\nprintf "%s\\n" "$@"\n');
    chmodSync(`${dir}/bin/curl`, 0o755);
    chmodSync(`${dir}/moon/bin/moon`, 0o755);
    const env = {
      ...process.env,
      PATH: `${dir}/bin:${process.env.PATH}`,
      MOON_HOME: `${dir}/moon`,
      GITHUB_PATH: `${dir}/github-path`,
      PIN_LOG: `${dir}/pin-log`,
    };
    const result = spawnSync("bash", [`${dir}/scripts/install-moon.sh`], { env, encoding: "utf8" });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(readFileSync(`${dir}/pin-log`, "utf8"), "0.10.13+cbb11c36f\n");
    assert.equal(readFileSync(env.GITHUB_PATH, "utf8"), `${dir}/moon/bin\n`);
    assert.equal(result.stdout, "version\n--all\n");

    for (const version of ["latest", "nightly", "", "0.10.13"]) {
      writeFileSync(`${dir}/.moonbit-version`, version);
      rmSync(env.PIN_LOG);
      const invalid = spawnSync("bash", [`${dir}/scripts/install-moon.sh`], { env, encoding: "utf8" });
      assert.equal(invalid.status, 1, version);
      assert.match(invalid.stderr, /expected an exact compiler version and revision/);
      assert.throws(() => readFileSync(env.PIN_LOG), /ENOENT/);
      writeFileSync(env.PIN_LOG, "");
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
