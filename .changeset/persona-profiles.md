---
"karinto": patch
---

Add `persona` analysis profiles (`regular` / `pedantic` / `auditor`), mirroring
zizmor's persona model. Each finding declares the minimum persona at which it
surfaces and the linter filters to the requested level (`regular ⊂ pedantic ⊂
auditor`). The default is `auditor`, so the bare endpoint and CLI keep reporting
every finding; pass `persona=regular` to match a stock zizmor run.

Pedantic findings: `anonymous-definition`, `self-hosted-runner`,
`undocumented-permissions`, and the `template-injection` Info backstop. Auditor
findings: `secrets-outside-env` and `misfeature`'s `defaults.run.shell: cmd`.
Available as the `persona` HTTP parameter (invalid values return `400`) and the
CLI `--persona` flag. The response schema is unchanged.
