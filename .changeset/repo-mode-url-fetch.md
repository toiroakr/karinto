---
"karinto": minor
---

Repo mode: accept GitHub URL shapes / branch refs, add whole-repo discovery, and gate it behind `REPO_MODE_ENABLED`.

The `repo`-mode endpoints now go beyond `/owner/repo/<sha>/<path>`:

- **Domain-swap a GitHub file URL.** `/owner/repo/{blob,tree,raw}/<ref>/<path>`
  is accepted, so swapping `github.com` for the Worker host on a file URL lints
  it. The `ref` can be a branch / tag / `HEAD` / SHA (new `ref=` parameter,
  resolved to that ref's latest commit); `commit=` stays a SHA-only immutable
  pin. The response echoes `ref`, and `commit` only for SHA pins.
- **Whole-repo discovery.** Bare `/owner/repo` (or `repo=` with no `targets`)
  lints every `.github/workflows/*.{yml,yaml}` file on the default branch via
  the GitHub contents API. This is the only request-path GitHub API call; it
  returns `429` with an actionable message when rate-limited.
- **Opt-in.** Repo mode (all of the above plus the existing forms) is now
  **disabled by default** and enabled per deployment via the `REPO_MODE_ENABLED`
  variable — it fetches arbitrary public content and draws on GitHub's rate
  limits. Posting the YAML as `content` is always available and is the
  recommended input. Disabled deployments return `403` for repo-mode requests.
- **Optional auth.** A `GITHUB_PUBLIC_READ_TOKEN` secret, when set, is mirrored
  into each Worker at deploy time and raises the contents-API ceiling from the
  unauthenticated 60 req/hour/IP to 5000/hour (and reaches private repos).

The GitHub Pages playground now fetches files in the browser and POSTs their
content to the linter, so its Repo / GitHub URL tabs no longer depend on the
Worker's repo mode; the **Paste YAML** tab is the default.

Path-based kind detection (repo mode + playground) now matches the CLI and
ghalint's conventions: a file under `.github/workflows/` is always a workflow
(any basename), and only an exact `action.yml` / `action.yaml` basename is an
action — fixing a false positive where a workflow like `release-action.yml` was
hinted as an action.
