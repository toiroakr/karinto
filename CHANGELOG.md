# karinto

## 0.1.0

### Minor Changes

- [#1](https://github.com/toiroakr/karinto/pull/1) [`4f4267c`](https://github.com/toiroakr/karinto/commit/4f4267c5a31c7ca25f7f0d9dc79dfbbc482f8636) Thanks [@toiroakr](https://github.com/toiroakr)! - Initial release.

  - MoonBit lint engine (`karinto.mbt` + `rules.mbt`) with 62 implemented rules
    derived from actionlint, zizmor, and ghalint. 22 additional rules are
    scaffolded as `#skip` specs.
  - Cloudflare Worker (`cf/index.js`) accepting `GET`/`POST` with workflow YAML,
    form-encoded params, JSON body, or repo-mode dispatch.
  - OSV.dev integration for `known-vulnerable-actions` (opt-in via `osv=1`).
  - Curl-driven smoke check at `cf/smoke.sh` runnable as `npm run smoke`.
  - Changesets-managed Release PR flow that cuts the production deploy and
    GitHub Release on merge.
  - Per-PR preview Workers (`karinto-pr-<N>.toiroakr.workers.dev`) auto-deployed
    and cleaned up.
  - Staging Worker (`karinto-staging.toiroakr.workers.dev`) auto-deployed on
    every push to `main`.
