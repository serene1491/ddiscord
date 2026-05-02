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

RUN_SOAK="${RELEASE_RUN_SOAK:-0}"
if [[ "$RUN_SOAK" != "0" && "$RUN_SOAK" != "1" ]]; then
    echo "error: RELEASE_RUN_SOAK must be 0 or 1" >&2
    exit 2
fi

SOAK_SECONDS="${RELEASE_SOAK_SECONDS:-300}"
SOAK_IDLE_PROBE_AFTER_SECONDS="${RELEASE_SOAK_IDLE_PROBE_AFTER_SECONDS:-180}"
if ! [[ "$SOAK_SECONDS" =~ ^[0-9]+$ ]]; then
    echo "error: RELEASE_SOAK_SECONDS must be a non-negative integer" >&2
    exit 2
fi
if ! [[ "$SOAK_IDLE_PROBE_AFTER_SECONDS" =~ ^[0-9]+$ ]]; then
    echo "error: RELEASE_SOAK_IDLE_PROBE_AFTER_SECONDS must be a non-negative integer" >&2
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

if [[ "$RUN_SOAK" == "1" ]]; then
    echo
    echo "==> [preflight] soak idle-recovery gate"
    (
        cd "$ROOT_DIR"
        SOAK_RUN_SECONDS="$SOAK_SECONDS" \
            SOAK_IDLE_PROBE_AFTER_SECONDS="$SOAK_IDLE_PROBE_AFTER_SECONDS" \
            ./scripts/soak_idle_recovery.sh
    )
fi

echo
echo "==> [preflight] completed"
