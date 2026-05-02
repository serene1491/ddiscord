#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load token/runtime variables from scripts/.env(.local) when present.
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/load_env.sh"
load_script_env

BOT_SECONDS="${RELEASE_BOT_SECONDS:-20}"
if ! [[ "$BOT_SECONDS" =~ ^[0-9]+$ ]]; then
    echo "error: RELEASE_BOT_SECONDS must be a non-negative integer" >&2
    exit 2
fi

echo "==> [preflight] dub test"
(
    cd "$ROOT_DIR"
    dub test
)

echo
echo "==> [preflight] build examples (+ optional live test-bot)"
(
    cd "$ROOT_DIR"
    ./scripts/test.sh --bot-seconds "$BOT_SECONDS"
)

echo
echo "==> [preflight] completed"
