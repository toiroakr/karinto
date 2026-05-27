---
"karinto": minor
---

Make the engine pinnable for reproducible CI. Every response now carries an
`engine_version` field (on both success and error paths) so callers can assert
the deployed engine hasn't drifted. Each release additionally deploys an
immutable snapshot Worker at `karinto-vX-Y-Z.toiroakr.workers.dev` (dots →
dashes), frozen to that release's bundle, so CI can `curl` a fixed version
instead of the always-latest endpoint and only adopt newer rules deliberately.
