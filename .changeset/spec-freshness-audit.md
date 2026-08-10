---
"karinto": patch
---

Refreshed several hardcoded GitHub Actions spec tables that had drifted, both from GitHub's docs and from actionlint's own stalled backlog (actionlint's main branch hasn't shipped a release since 2026-03-30). This closes false positives/negatives across five rules:

- `permissions-syntax` — added the `artifact-metadata`, `code-quality`, `copilot-requests`, and `vulnerability-alerts` scopes; removed `repository-projects` (Projects classic, sunset 2024-08-23) and `models` (GitHub Models, retired 2026-07-30).
- `unknown-runner-label` — added `ubuntu-26.04`/`ubuntu-26.04-arm` (public preview), `windows-2025-vs2026`/`windows-11-vs2026-arm` (preview), the `macos-26`/`macos-15-intel`/`macos-26-intel`/`macos-26-large`/`macos-26-xlarge` labels, and the preview `xcode-27`/`xcode-27-xlarge` labels (documented only in the `actions/runner-images` README so far, not yet in github/docs); removed `ubuntu-20.04`, `windows-2019`, `macos-12`, and `macos-13`, none of which resolve to a real hosted-runner image anymore.
- `webhook-events` — added the `image_version` trigger; removed the Projects-classic `project`/`project_card`/`project_column` events.
- `unexpected-keys` — added the `snapshot` job key and the `background`/`wait`/`wait-all`/`cancel`/`parallel` step keys (async step execution, shipped alongside experimental parallel steps).
- `uses-syntax` — `uses: $/path/to/action` (the same-repository reference syntax GitHub added 2026-07-30, no `@ref` suffix) is no longer misreported as missing an `@ref`.

Also added a weekly `spec-freshness` CI job (see issue #111) that diffs these tables against github/docs and `actions/runner-images` and files a tracking issue on drift, so future gaps like these get caught automatically instead of accumulating silently the way they did upstream.
