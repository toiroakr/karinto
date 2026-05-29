# Versioning & pinning

`https://karinto.toiroakr.workers.dev` always serves the latest release. That
convenience cuts both ways: a new rule landing — or an existing one
tightening — can start failing a workflow you never touched. This document
walks through the ways to stop the behavior from shifting under your CI.

## TL;DR

| Approach | Setup cost | Update cadence | When to use |
| --- | --- | --- | --- |
| **Exact pin** (`karinto-vX-Y-Z.toiroakr.workers.dev`) | change one URL | controlled (the [Renovate preset](#renovate-auto-bump) can auto-PR) | typical CI case |
| **Major alias** (`karinto-vX.toiroakr.workers.dev`) | change one URL | auto-rolls within major | "track the latest `0.Y.Z`, just shield me from `1.0.0`" |
| **Self-host** on your own Cloudflare account | one-time | you control | needs lifetime guarantees beyond upstream retention, or want a fully isolated deployment |

Every response carries an `engine_version` field on both success and error
paths so you can `jq -e '.engine_version == "0.3.1"'` against the bare
endpoint to detect drift even without a URL pin.

## Pinned URL

Each release deploys two extra Workers alongside the always-latest one:

- `https://karinto-vX-Y-Z.toiroakr.workers.dev` — an immutable snapshot
  frozen to that release's bundle (dots → dashes, e.g. `0.3.1` →
  `karinto-v0-3-1`).
- `https://karinto-vX.toiroakr.workers.dev` — a **major alias** that
  tracks the latest patch within major `X`. Rolls forward across
  `0.3.1 → 0.3.2 → 0.4.0` but is shielded from a future `1.0.0`.

Point CI at one of these and bump it deliberately when you want the newer
rules:

```sh
# Maximally strict: never moves without you re-pinning.
curl -X POST --data-binary @.github/workflows/ci.yml \
     https://karinto-v0-3-1.toiroakr.workers.dev

# Auto-update within major (new rules + bug fixes, no breaking changes).
curl -X POST --data-binary @.github/workflows/ci.yml \
     https://karinto-v0.toiroakr.workers.dev
```

Both forms keep karinto's curl model: you POST YAML and receive JSON; no
third-party code runs inside your runner.

### Retention and the 404 risk

Exact-version pinned Workers are auto-pruned on each release. The keep set
(see [`scripts/manage-pinned-workers.mjs`](../scripts/manage-pinned-workers.mjs))
is:

> *(latest patch within every major)* ∪ *(top `PINNED_KEEP_RECENT` by
> SemVer, default 30)* ∪ *(just-released)*

A given `karinto-vX-Y-Z` URL is preserved as long as your pinned release is
either the most recent patch in its major *or* one of the most recent 30
releases overall. It falls out and gets deleted once **both** of those
have stopped holding: a strictly newer release in your major has shipped
(so you've lost "latest patch within major") *and* your pin has slid out
of the global top 30 by SemVer (releases in *any* major count toward the
top-30 budget, so heavy patching of a newer major can push out an old pin
even when relatively few releases in your own major have happened).
Hitting the URL afterward returns the Cloudflare "worker not found"
`404`, not a karinto-shaped JSON response.

If you can't afford `404` when you forget to bump the pin:

1. **Use the [Renovate preset](#renovate-auto-bump).** It opens a PR each
   time a new version ships so the URL never lags far behind the retention
   window.
2. **Pin to the major alias instead.** `karinto-vX` is never auto-deleted;
   it tracks the latest patch within its major. You give up "freeze
   exactly this patch" semantics in exchange for a never-`404` contract.
3. **[Self-host](#self-host-on-cloudflare).** Deploy your own copy and pin
   to your URL. Lifetime is entirely under your control.

Major aliases (`karinto-vX`) are never auto-deleted — they outlive any
particular patch and represent the long-lived "track this major" contract.

## Self-host on Cloudflare

For deployments that need lifetime guarantees beyond the upstream
retention, or organizations that prefer not to depend on a third-party
endpoint at all, the karinto Worker can be deployed against your own
Cloudflare account.

**Prerequisites:**

- A Cloudflare account with Workers enabled. The free plan is sufficient
  for basic deployment; the rate-limit binding the upstream uses
  (`unsafe.bindings[].type: ratelimit`) is a Workers Paid feature — drop
  it if you're on the free plan and the Worker will fall open.
- [`moon`](https://docs.moonbitlang.com) — to build the MoonBit engine.
- Node 22+ — for `wrangler`.

**Steps:**

1. **Check out the repo at the release tag you want.** For reproducibility,
   prefer a release tag over `main`:

   ```sh
   git clone --depth=1 --branch v0.3.1 https://github.com/toiroakr/karinto.git
   cd karinto
   ```

2. **Build the MoonBit engine bundle:**

   ```sh
   moon update
   moon build --target js --release
   ```

3. **Install the Worker dependencies:**

   ```sh
   cd cf
   npm ci
   ```

4. **Edit `cf/wrangler.jsonc`** to remove upstream-specific bindings:

   - Replace `name` with your own (e.g. `my-karinto`).
   - Replace each `kv_namespaces[].id` with a KV namespace you've created
     in your account (`npx wrangler kv namespace create karinto-meta`), or
     remove the `kv_namespaces` block entirely if you don't need the
     GitHub Actions IP allow-list cache (the Worker falls back to a
     direct `api.github.com/meta` fetch when KV is missing).
   - Remove the `unsafe.bindings` `RATE_LIMITER_IP` block unless you're on
     Workers Paid. The Worker falls open without it.
   - Remove `env.production.r2_buckets` — that wires up the upstream
     dark-launch capture store and isn't useful for self-hosters.
   - Remove `env.production.triggers` unless you want the daily
     `api.github.com/meta` refresh cron.

5. **Deploy:**

   ```sh
   npx wrangler deploy --env=""
   ```

6. **Point CI at your URL:**

   ```sh
   curl -X POST --data-binary @workflow.yml \
        https://my-karinto.<your-subdomain>.workers.dev
   ```

Lifetime is entirely up to you — nothing upstream can prune your Worker.
If you want to follow upstream releases, add a scheduled CI job in your
fork that re-runs the build + deploy.

The `engine_version` field still works in a self-hosted deployment — it
reflects the version of the karinto bundle you built (sourced from
`package.json` and inlined at deploy time).

## Renovate auto-bump

The repo ships a Renovate preset that auto-PRs version bumps for the
exact-pin URL and the `engine_version` assertion forms above. Extending it
from your repo's `renovate.json` is one line:

```json
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": [
    "config:recommended",
    "github>toiroakr/karinto:pin"
  ]
}
```

The preset registers two regex-based [custom managers](https://docs.renovatebot.com/configuration-options/#custommanagers):

- **Exact-pin URL** — matches `karinto-vX-Y-Z.toiroakr.workers.dev` in
  `.github/workflows/*.{yml,yaml}`, `*.sh`, and `Makefile`s. Updates the
  dashed form in place by reading dashed git tags pushed alongside each
  release (`v0-3-2` is a lightweight pointer to the same commit as
  `v0.3.2`).
- **`engine_version` assertion** — matches `engine_version == "X.Y.Z"`
  (single or double quotes) in the same file set. Updates the dotted form
  against GitHub Releases.

The major alias `karinto-vX` doesn't need Renovate — it auto-rolls within
its major silently. Renovate only surfaces a bump once a new major (e.g.
`1.0.0`) is tagged, at which point you can decide whether to migrate.

Apply standard Renovate package rules via `matchDepNames: ["toiroakr/karinto"]`
to group, schedule, or auto-merge karinto bumps:

```json
{
  "packageRules": [
    {
      "matchDepNames": ["toiroakr/karinto"],
      "groupName": "karinto",
      "automerge": true
    }
  ]
}
```
