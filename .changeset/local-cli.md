---
"karinto": minor
---

Turn `cmd/main` into a usable local CLI (#34).

`cmd/main` was a build sanity-check that linted a hard-coded workflow. It is
now a real CLI that runs locally with MoonBit's js backend (Node.js):

- Reads YAML from **stdin** (`cat workflow.yml | moon run --target js cmd/main`)
  or from **file path arguments**
  (`moon run --target js cmd/main -- .github/workflows/ci.yml action.yml`).
- Reuses the same `@karinto.lint` engine as the Worker, with the same knobs:
  `--type workflow|action` (auto-detected when omitted — file paths also get a
  filename hint: `action.yml` basenames and `.github/workflows/` paths) and
  `--disable` comma-separated rule-ID globs (repeatable).
- Prints the same JSON envelope as the Worker (`{ok, result}` for stdin;
  `{ok, files: [{path, ok, result}, ...]}` for file arguments).
- CI-friendly exit codes: `0` clean, `1` error-severity diagnostics or YAML
  parse errors, `2` usage / IO errors. `moon run` swallows exit codes, so for
  CI run the built bundle directly:
  `moon build --target js --release && node _build/js/release/build/cmd/main/main.js <files>`.
