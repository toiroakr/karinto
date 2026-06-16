---
"karinto": patch
---

Fix persona gating for `concurrency-limits` and `excessive-permissions` so
`persona=regular` matches a default `zizmor` run. Validating against real
zizmor-using OSS workflows showed karinto emitting two findings at `regular`
that zizmor only emits under `--pedantic`:

- `concurrency-limits` is now `pedantic` (it was `regular`).
- `excessive-permissions` is split: the per-key `<x>: write is overly broad`
  finding is `pedantic`; the blanket `write-all`/`read-all` and "default
  permissions used" findings stay `regular`.
