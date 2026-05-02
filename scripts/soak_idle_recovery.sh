#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load token/runtime variables from scripts/.env(.local) when present.
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/load_env.sh"
load_script_env

RUN_SECONDS="${SOAK_RUN_SECONDS:-300}"
IDLE_PROBE_AFTER_SECONDS="${SOAK_IDLE_PROBE_AFTER_SECONDS:-180}"

if ! [[ "$RUN_SECONDS" =~ ^[0-9]+$ ]]; then
    echo "error: SOAK_RUN_SECONDS must be a non-negative integer" >&2
    exit 2
fi

if ! [[ "$IDLE_PROBE_AFTER_SECONDS" =~ ^[0-9]+$ ]]; then
    echo "error: SOAK_IDLE_PROBE_AFTER_SECONDS must be a non-negative integer" >&2
    exit 2
fi

if [[ "$RUN_SECONDS" -eq 0 ]]; then
    echo "error: SOAK_RUN_SECONDS must be greater than 0 for soak mode" >&2
    exit 2
fi

if [[ "$IDLE_PROBE_AFTER_SECONDS" -gt "$RUN_SECONDS" ]]; then
    echo "error: SOAK_IDLE_PROBE_AFTER_SECONDS cannot exceed SOAK_RUN_SECONDS" >&2
    exit 2
fi

if [[ -z "${DISCORD_TOKEN:-}" && -z "${TOKEN:-}" ]]; then
    echo "error: DISCORD_TOKEN/TOKEN is required for soak mode" >&2
    exit 2
fi

echo "==> [soak] run seconds: $RUN_SECONDS"
echo "==> [soak] idle probe after: $IDLE_PROBE_AFTER_SECONDS"
echo "==> [soak] building examples + running test-bot soak"

(
    cd "$ROOT_DIR"
    ./scripts/test.sh \
        --bot-seconds "$RUN_SECONDS" \
        --idle-probe-after "$IDLE_PROBE_AFTER_SECONDS"
)

echo "==> [soak] completed"
