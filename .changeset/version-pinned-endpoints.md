---
"karinto": minor
---

Make the engine pinnable for reproducible CI. Every response now carries an
`engine_version` field (on both success and error paths) so callers can assert
the deployed engine hasn't drifted.

Each release additionally deploys two extra Workers alongside the always-latest
one:

- `karinto-vX-Y-Z.toiroakr.workers.dev` — an immutable snapshot frozen to
  that release's bundle (dots → dashes). The maximally-strict pin for CI.
- `karinto-vX.toiroakr.workers.dev` — a major alias that tracks the latest
  patch within major `X`. Rolls forward across patches and minors, shielded
  from breaking-change bumps.

Exact-version snapshots are auto-pruned on each release down to *(the latest
patch within every major)* ∪ *(the top `PINNED_KEEP_RECENT` versions by
SemVer, default 5)* ∪ *(the just-released version)*, so the latest patch of
every released major remains available as an exact pin indefinitely. Major
aliases are never auto-deleted.
