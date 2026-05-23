---
"karinto": minor
---

Add a GitHub Pages playground (`docs/index.html`) where users can enter
`owner/repo` and a workflow/action file path; the page resolves the latest
commit on the default branch via the GitHub API and calls the karinto
Worker, showing the JSON response inline. Deployment is automated through
`.github/workflows/deploy-pages.yml`.

The Worker (`cf/index.js`) now emits `Access-Control-Allow-Origin: *` on
every JSON response so browser-based clients (including the new
playground) can read the body. The API was already public and
credential-less, so this is purely additive.
