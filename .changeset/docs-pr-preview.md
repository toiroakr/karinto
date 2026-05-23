---
"karinto": patch
---

Add a `preview-pages` workflow that uploads `docs/` as an unzipped artifact
(`actions/upload-artifact@v7` with `archive: false`, Feb 2026 feature) on
every PR touching the docs. The sticky PR comment links straight to the
artifact so reviewers can open `index.html` in the browser without a
GitHub Pages deploy.
