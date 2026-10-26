Refresh upstream linter pins (auto-generated).

| tool | from | to | release | compare |
| --- | --- | --- | --- | --- |
| ghalint | 1.5.6 | 1.5.7 | [v1.5.7](https://github.com/suzuki-shunsuke/ghalint/releases/tag/v1.5.7) | [`v1.5.6...v1.5.7`](https://github.com/suzuki-shunsuke/ghalint/compare/v1.5.6...v1.5.7) |

Fixtures under `fixtures/upstream/<tool>/` were re-vendored from the new tag. This PR is opened with `GITHUB_TOKEN`, so `upstream-parity` does **not** run automatically — add the `run-parity` label to trigger it. Its step summary then lists any divergences (`unmapped` / soft) that point at newly-added upstream checks.

## Upstream release notes

<details><summary><b>ghalint</b> v1.5.7</summary>

https://github.com/suzuki-shunsuke/ghalint/compare/v1.5.6...v1.5.7

## :warning: Security

#1507 Update Go to v1.27.3

This release is built with Go 1.27.3, which fixes [CVE-2026-111943](https://go.dev/issue/82345) in `crypto/x509`. Go now refuses trust in a small set of intermediate certificates of a specific Certificate Authority, after its CA keys were reported compromised. `Verify` filters out chains containing those intermediates. The Go team highly recommends upgrading immediately.

ghalint relies on `crypto/x509` to verify the TLS certificate of the GitHub API, which `ghalint experiment validate-input` calls. Other commands don't access the network.

ref.

- https://go.dev/doc/devel/release#go1.27.3
- https://thehackernews.com/2026/10/eight-emudhra-ca-keys-compromised.html

v1.5.6 was built with Go 1.26.2. This release also includes Go 1.26.3 (#1325), 1.26.4 (#1357), 1.26.5 (#1396), 1.26.6 (#1428), and 1.27.2 (#1490), which have security fixes to the `go` command, the `pack` tool, and the `crypto/tls`, `crypto/x509`, `encoding/asn1`, `encoding/xml`, `html/template`, `mime`, `net`, `net/http`, `net/http/httputil`, `net/mail`, `net/textproto`, `net/url`, `os`, and `syscall` packages.

- https://go.dev/doc/devel/release#go1.26.3
- https://go.dev/doc/devel/release#go1.26.4
- https://go.dev/doc/devel/release#go1.26.5
- https://go.dev/doc/devel/release#go1.26.6
- https://go.dev/doc/devel/release#go1.27.2

## ⚠️ Changes of Release Assets

The ghalint

…(truncated — see release link)

</details>

## Incorporation checklist

If the parity step summary surfaces an `unmapped` / soft divergence (an upstream check karinto does not yet cover), follow the incorporation flow in [`DEVELOPMENT.md`](https://github.com/toiroakr/karinto/blob/main/DEVELOPMENT.md#incorporating-a-new-upstream-check):

- [ ] Reviewed the `compare` diff + release notes above for new / changed checks.
- [ ] Added the `run-parity` label and checked the `upstream-parity` step summary for `unmapped` rule IDs / Kinds.
- [ ] For each new check: registered it in `rules_catalog.mbt` (+ mirrored `rules_catalog.md`) with a status, or recorded the intentional divergence in `scripts/upstream-parity/allowlist.json`.
- [ ] `moon test` + local parity pass.
