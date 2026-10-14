#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
VERSION=$(cat "$ROOT/.moonbit-version")
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+\+[0-9a-f]+$ ]]; then
  echo "Invalid .moonbit-version: expected an exact compiler version and revision" >&2
  exit 1
fi

curl -fsSL https://cli.moonbitlang.com/install/unix.sh | bash -s -- "$VERSION"
MOON_BIN="${MOON_HOME:-$HOME/.moon}/bin"
if [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "$MOON_BIN" >> "$GITHUB_PATH"
fi
"$MOON_BIN/moon" version --all
