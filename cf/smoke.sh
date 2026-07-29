#!/usr/bin/env bash
# Curl-based smoke check for the deployed karinto Worker.
#
#   ./cf/smoke.sh                          # hits https://karinto.toiroakr.workers.dev
#   ./cf/smoke.sh https://other.workers.dev
#
# Exits non-zero if any check fails. Requires `jq`.
set -euo pipefail

URL="${1:-https://karinto.toiroakr.workers.dev}"
printf 'smoke-testing %s\n' "$URL"

# Newly deployed workers.dev hostnames can take 30s+ to propagate on the
# very first deploy, and readiness flaps across edge PoPs while it spreads:
# one probe can hit a warm colo while the next lands on a cold one that still
# answers 404 or a plain-text Cloudflare error (e.g. 1042), which would break
# the jq-based checks below. So wait for both code paths to return their
# *expected* codes (yaml body → 200, empty body → 400) three times in a row
# before asserting anything. 36 × 5s ≈ 3 min total budget.
#
# The streak is necessary but not sufficient — propagation has been observed to
# flap again *after* it is satisfied — so the checks themselves retry too, via
# the `http_probe` / `get_ok` wrappers defined below.
streak=0
for attempt in $(seq 1 36); do
  body_code=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' -X POST --data 'name: t' "$URL" || true)
  empty_code=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' -X POST --data '' "$URL" || true)
  if [ "$body_code" = "200" ] && [ "$empty_code" = "400" ]; then
    streak=$((streak + 1))
    if [ "$streak" -ge 3 ]; then
      break
    fi
  else
    streak=0
    printf '  waiting for %s (attempt %s, body=%s empty=%s)\n' "$URL" "$attempt" "$body_code" "$empty_code"
  fi
  sleep 5
done
if [ "$streak" -lt 3 ]; then
  printf 'error: %s did not become ready within the wait budget\n' "$URL" >&2
  exit 1
fi

failed=0
ok()  { printf "  ok   %s\n" "$1"; }
bad() { printf "  fail %s\n" "$1"; failed=1; }

# A request issued after the readiness streak can still land on a colo that has
# not picked up the route. Every check therefore goes through one of the two
# wrappers below rather than calling curl directly, and neither of them aborts
# the script: a bare `curl -f` under `set -e` turns a transient 404 into exit 22
# and kills the run outright — no `fail` line, no summary, just `curl: (22)` —
# which is exactly how a flap once took down a deploy-preview job.
#
# 3 retries rather than more because every probe now retries, not just the ones
# that used to run under `curl -f`. Observed flaps have always cleared within a
# single 5s readiness tick.
RETRIES=3
RETRY_DELAY=3
MAX_TIME=20

# Per-probe worst case is 4 × 20s + 3 × 3s ≈ 89s, and there are up to 15 probes
# below — far more than the workflow's 15-minute job timeout would allow. A job
# killed on timeout prints no summary, which is the very failure mode this file
# is trying to eliminate, so the assertion phase gets its own wall-clock budget.
# Past it, `http_probe` stops retrying and collapses curl's timeout to a second,
# letting the remaining checks fail fast and the summary still run. The readiness
# gate above can burn 3 of the job's 15 minutes; 8 leaves margin for the build
# and deploy steps that precede this script.
CHECKS_DEADLINE=$((SECONDS + 480))

# `http_probe <body-file> <curl args...>` writes the response body to
# <body-file> and echoes the status code. Retries while the edge answers 404,
# 5xx, or 000 (curl's placeholder for a request that never completed) — the
# shapes an unpropagated route produces. No check below expects any of those,
# so retrying can never mask a real regression. The URL must come last.
http_probe() {
  local out=$1
  shift
  local attempt budget delay max_time code=''
  for attempt in $(seq 0 "$RETRIES"); do
    if [ "$attempt" -gt 0 ]; then
      # Consult the budget *before* backing off, not after. An exhausted budget
      # means there is nothing left to wait for, so stop instead of spending a
      # delay on an attempt whose curl would be clamped to a second anyway; and
      # cap the delay itself so a backoff started just inside the budget cannot
      # overshoot the deadline it is meant to respect.
      delay=$((CHECKS_DEADLINE - SECONDS))
      if [ "$delay" -le 0 ]; then break; fi
      if [ "$delay" -gt "$RETRY_DELAY" ]; then delay=$RETRY_DELAY; fi
      sleep "$delay"
    fi
    budget=$((CHECKS_DEADLINE - SECONDS))
    if [ "$budget" -lt 1 ]; then budget=1; fi
    max_time=$MAX_TIME
    if [ "$max_time" -gt "$budget" ]; then max_time=$budget; fi
    code=$(curl -sS --max-time "$max_time" -o "$out" -w '%{http_code}' "$@" || true)
    case "$code" in
      404 | 5?? | 000) ;;
      *) break ;;
    esac
  done
  printf '%s' "$code"
}

# `get_ok <curl args...>` echoes the response body for the checks that only ever
# expect a 2xx. It never aborts: on any other status it echoes a deliberately
# non-JSON marker instead, so the caller's own jq assertion fails and reports it
# through `bad` — the remaining checks still run and the summary is still
# printed. It cannot call `bad` itself: callers use `$(get_ok ...)`, so both the
# message and the `failed=1` would be trapped in the substitution's subshell.
get_ok() {
  local url=${*: -1}
  local out body code
  out=$(mktemp)
  code=$(http_probe "$out" "$@")
  body=$(cat "$out")
  rm -f "$out"
  case "$code" in
    2??) printf '%s' "$body" ;;
    *)   printf 'HTTP %s from %s: %s' "$code" "$url" "$body" ;;
  esac
}

YAML='name: ci
on: push
permissions: write-all
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi'

# 1. POST raw YAML -> result includes permissions-write-all-forbidden
res=$(get_ok -X POST --data-binary "$YAML" "$URL")
if jq -e '.ok and (.result.diagnostics | map(.rule) | any(. == "permissions-write-all-forbidden"))' >/dev/null <<<"$res"; then
  ok "POST yaml body -> permissions-write-all-forbidden"
else
  bad "POST yaml body: $res"
fi

# 2. disable=permissions-* suppresses every permissions-* rule
res=$(get_ok --data-urlencode "content=$YAML" --data "disable=permissions-*" "$URL")
if jq -e '.ok and (.result.diagnostics | map(.rule) | all(startswith("permissions-") | not))' >/dev/null <<<"$res"; then
  ok "disable=permissions-* suppresses permissions-* rules"
else
  bad "disable filter: $res"
fi

# 3. empty body -> 400
code=$(http_probe /dev/null -X POST --data '' "$URL")
if [ "$code" = "400" ]; then
  ok "empty body -> 400"
else
  bad "empty body returned $code"
fi

# Repo mode (the GitHub-fetching `/owner/repo[/...]` endpoints) is opt-in via
# the REPO_MODE_ENABLED deployment variable. Detect the deployment's setting
# with a request that can't trigger any GitHub fetch — an invalid repo slug: a
# disabled deployment 403s at the gate, an enabled one reaches validation (400).
gate=$(http_probe /dev/null "$URL?repo=not-a-slug")
case "$gate" in
  403) REPO_MODE=off ;;
  400) REPO_MODE=on ;;
  *)   REPO_MODE=unknown ;;
esac
printf '  repo mode: %s (gate probe -> %s)\n' "$REPO_MODE" "$gate"

if [ "$REPO_MODE" = off ]; then
  # 4. repo mode disabled -> 403 with an explanatory error.
  res_body=$(mktemp)
  code=$(http_probe "$res_body" "$URL/actions/checkout/b4ffde65f46336ab88eb53be808477a3936bae11/action.yml")
  res=$(cat "$res_body"); rm -f "$res_body"
  if [ "$code" = "403" ] && jq -e '.ok == false and (.error | test("repo mode is disabled"))' >/dev/null <<<"$res"; then
    ok "repo mode disabled -> 403 at the gate"
  else
    bad "repo-mode gate (status=$code): $res"
  fi
elif [ "$REPO_MODE" = on ]; then
  # 4. repo without commit -> 400
  res_body=$(mktemp)
  code=$(http_probe "$res_body" "$URL?repo=actions/checkout&targets=action.yml")
  res=$(cat "$res_body"); rm -f "$res_body"
  if [ "$code" = "400" ] && jq -e '.ok == false and (.error | test("`commit` or `ref` is required"))' >/dev/null <<<"$res"; then
    ok "repo without commit/ref -> 400"
  else
    bad "repo without commit/ref (status=$code): $res"
  fi

  # 5. repo + non-hex commit (branch name) -> 400
  res_body=$(mktemp)
  code=$(http_probe "$res_body" "$URL?repo=actions/checkout&commit=main&targets=action.yml")
  res=$(cat "$res_body"); rm -f "$res_body"
  if [ "$code" = "400" ] && jq -e '.ok == false and (.error | test("invalid commit"))' >/dev/null <<<"$res"; then
    ok "repo + branch name commit -> 400"
  else
    bad "repo + branch name (status=$code): $res"
  fi

  # 6. path /<owner>/<repo>/<commit>/<target> resolves to a real lint
  res=$(get_ok "$URL/actions/checkout/b4ffde65f46336ab88eb53be808477a3936bae11/action.yml")
  if jq -e '.ok and .repo == "actions/checkout" and .commit == "b4ffde65f46336ab88eb53be808477a3936bae11" and (.files | length) == 1' >/dev/null <<<"$res"; then
    ok "path /owner/repo/commit/target -> repo lint"
  else
    bad "path-based repo lint: $res"
  fi

  # 7. path-traversal in targets -> 400 (must not escape the pinned commit prefix)
  res_body=$(mktemp)
  code=$(http_probe "$res_body" --data-urlencode 'targets=../main/action.yml' "$URL?repo=actions/checkout&commit=b4ffde65f46336ab88eb53be808477a3936bae11")
  res=$(cat "$res_body"); rm -f "$res_body"
  if [ "$code" = "400" ] && jq -e '.ok == false and (.error | test("invalid target path"))' >/dev/null <<<"$res"; then
    ok "targets with .. segment -> 400"
  else
    bad "targets with .. segment (status=$code): $res"
  fi

  # 8. percent-encoded path-traversal -> 400 (defense-in-depth)
  res_body=$(mktemp)
  code=$(http_probe "$res_body" --data-urlencode 'targets=%2e%2e%2fmain%2faction.yml' "$URL?repo=actions/checkout&commit=b4ffde65f46336ab88eb53be808477a3936bae11")
  res=$(cat "$res_body"); rm -f "$res_body"
  if [ "$code" = "400" ] && jq -e '.ok == false and (.error | test("invalid target path"))' >/dev/null <<<"$res"; then
    ok "percent-encoded traversal -> 400"
  else
    bad "percent-encoded traversal (status=$code): $res"
  fi

  # 9. domain-swapped GitHub blob URL (`/owner/repo/blob/<ref>/<path>`) resolves
  #    to a lint. Pinned to a SHA so the lint output is stable; response carries
  #    both `ref` and the echoed `commit`.
  res=$(get_ok "$URL/actions/checkout/blob/b4ffde65f46336ab88eb53be808477a3936bae11/action.yml")
  if jq -e '.ok and .ref == "b4ffde65f46336ab88eb53be808477a3936bae11" and .commit == "b4ffde65f46336ab88eb53be808477a3936bae11" and (.files | length) == 1' >/dev/null <<<"$res"; then
    ok "blob URL form /owner/repo/blob/<sha>/target -> repo lint"
  else
    bad "blob URL form: $res"
  fi

  # 10. branch ref via `ref=` lints the branch's latest commit. The response
  #     carries `ref` but no `commit` (no SHA resolved on the hot path).
  res=$(get_ok "$URL?repo=actions/checkout&ref=main&targets=action.yml")
  if jq -e '.ok and .ref == "main" and (has("commit") | not) and (.files | length) == 1' >/dev/null <<<"$res"; then
    ok "ref=main -> latest-commit lint, no echoed commit"
  else
    bad "ref=main branch lint: $res"
  fi

  # 11. ref with a `..` traversal segment -> 400 (can't escape into another path).
  res_body=$(mktemp)
  code=$(http_probe "$res_body" "$URL?repo=actions/checkout&ref=../main&targets=action.yml")
  res=$(cat "$res_body"); rm -f "$res_body"
  if [ "$code" = "400" ] && jq -e '.ok == false and (.error | test("invalid ref"))' >/dev/null <<<"$res"; then
    ok "ref with .. segment -> 400"
  else
    bad "ref with .. segment (status=$code): $res"
  fi
else
  bad "repo-mode gate probe returned unexpected status $gate"
fi

# 12. unrelated path (`/favicon.ico`) is ignored, so the body-less request
#     falls through to the standard `missing content or repo` 400 regardless
#     of the repo-mode setting (a 1-segment path is never repo mode).
res_body=$(mktemp)
code=$(http_probe "$res_body" "$URL/favicon.ico")
res=$(cat "$res_body"); rm -f "$res_body"
if [ "$code" = "400" ] && jq -e '.ok == false and (.error | test("missing"))' >/dev/null <<<"$res"; then
  ok "non-repo path falls through to missing-content 400"
else
  bad "non-repo path (status=$code): $res"
fi

# NOTE: whole-repo discovery (`/owner/repo` with no targets) is deliberately
# NOT smoke-tested here. It calls the GitHub contents API from the Worker's
# (Cloudflare) egress IP, which shares the unauthenticated 60-req/hour/IP
# budget with real user traffic — and smoke.sh runs on every deploy (twice in
# release-publish.sh: prod + pinned snapshot). Burning that scarce quota on a
# liveness probe is wasteful and could rate-limit genuine requests. The
# discovery path is covered by the mocked unit tests instead.

# 13. every response carries a non-empty `engine_version` so CI can pin /
#     assert the deployed engine (present on both success and error paths).
res=$(get_ok -X POST --data-binary "$YAML" "$URL")
if jq -e '(.engine_version | type == "string" and length > 0)' >/dev/null <<<"$res"; then
  ok "response carries engine_version ($(jq -r '.engine_version' <<<"$res"))"
else
  bad "engine_version missing on success: $res"
fi
res_body=$(mktemp)
code=$(http_probe "$res_body" -X POST --data '' "$URL")
res=$(cat "$res_body"); rm -f "$res_body"
if jq -e '(.engine_version | type == "string" and length > 0)' >/dev/null <<<"$res"; then
  ok "engine_version present on error path"
else
  bad "engine_version missing on error (status=$code): $res"
fi

exit "$failed"
