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

# Newly deployed workers.dev hostnames can take a few seconds to propagate.
# Different request shapes can warm up independently, so probe both the
# body-bearing and empty-body code paths until both stop returning 404.
for attempt in 1 2 3 4 5 6 7 8; do
  body_code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST --data 'name: t' "$URL" || true)
  empty_code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST --data '' "$URL" || true)
  if [ "$body_code" != "404" ] && [ "$body_code" != "000" ] \
     && [ "$empty_code" != "404" ] && [ "$empty_code" != "000" ]; then
    break
  fi
  printf '  waiting for %s (attempt %s, body=%s empty=%s)\n' "$URL" "$attempt" "$body_code" "$empty_code"
  sleep 5
done

YAML='name: ci
on: push
permissions: write-all
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi'

failed=0
ok()  { printf "  ok   %s\n" "$1"; }
bad() { printf "  fail %s\n" "$1"; failed=1; }

# 1. POST raw YAML -> result includes permissions-write-all-forbidden
res=$(curl -fsS -X POST --data-binary "$YAML" "$URL")
if jq -e '.ok and (.result.diagnostics | map(.rule) | any(. == "permissions-write-all-forbidden"))' >/dev/null <<<"$res"; then
  ok "POST yaml body -> permissions-write-all-forbidden"
else
  bad "POST yaml body: $res"
fi

# 2. disable=permissions-* suppresses every permissions-* rule
res=$(curl -fsS --data-urlencode "content=$YAML" --data "disable=permissions-*" "$URL")
if jq -e '.ok and (.result.diagnostics | map(.rule) | all(startswith("permissions-") | not))' >/dev/null <<<"$res"; then
  ok "disable=permissions-* suppresses permissions-* rules"
else
  bad "disable filter: $res"
fi

# 3. empty body -> 400
code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST --data '' "$URL")
if [ "$code" = "400" ]; then
  ok "empty body -> 400"
else
  bad "empty body returned $code"
fi

exit "$failed"
