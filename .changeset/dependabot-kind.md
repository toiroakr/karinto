---
"karinto": minor
---

Promote Dependabot config to a first-class file kind.

`.github/dependabot.yml` is neither a workflow nor an action, so it was
previously lumped into the `Unknown` kind and the Dependabot rules
(`dependabot-cooldown`, `dependabot-execution`) rode along on an
`unknown_only` predicate. It is now a proper `FileKind::Dependabot`:

- **Detection** — content-based auto-detect classifies a top-level `updates:`
  key as Dependabot (it is unique to dependabot config; workflows/actions never
  carry it), and the path-based hints (Worker repo mode, CLI, playground) map
  `.github/dependabot.yml` / `.yaml` to it — mirroring how
  `.github/workflows/*` and `action.yml` are recognised.
- **Explicit override** — `type=dependabot` (API) / `--type dependabot` (CLI)
  force it.
- The Dependabot rules now run only when the kind is `Dependabot`, and a lint
  of a dependabot config reports `"kind": "dependabot"`.

This also clears the way for a future "could not determine kind" hint on the
genuinely-`Unknown` case without false-positiving on dependabot config.
