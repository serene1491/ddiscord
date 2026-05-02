#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXAMPLES_DIR="$ROOT_DIR/examples"

# Load token/runtime variables from scripts/.env(.local) when present.
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/load_env.sh"
load_script_env

DEFAULT_BOT_SECONDS="${TEST_BOT_RUN_SECONDS:-45}"
DEFAULT_IDLE_PROBE_AFTER_SECONDS="${TEST_BOT_IDLE_PROBE_AFTER_SECONDS:-0}"
BOT_SECONDS="$DEFAULT_BOT_SECONDS"
IDLE_PROBE_AFTER_SECONDS="$DEFAULT_IDLE_PROBE_AFTER_SECONDS"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --bot-seconds)
            if [[ -z "${2:-}" ]]; then
                echo "error: missing value for --bot-seconds" >&2
                exit 2
            fi
            BOT_SECONDS="$2"
            shift 2
            ;;
        --idle-probe-after)
            if [[ -z "${2:-}" ]]; then
                echo "error: missing value for --idle-probe-after" >&2
                exit 2
            fi
            IDLE_PROBE_AFTER_SECONDS="$2"
            shift 2
            ;;
        *)
            echo "error: unsupported arguments: $*" >&2
            echo "usage: $0 [--bot-seconds <seconds>] [--idle-probe-after <seconds>]" >&2
            exit 2
            ;;
    esac
done

if ! [[ "$BOT_SECONDS" =~ ^[0-9]+$ ]]; then
    echo "error: --bot-seconds must be a non-negative integer" >&2
    exit 2
fi

if ! [[ "$IDLE_PROBE_AFTER_SECONDS" =~ ^[0-9]+$ ]]; then
    echo "error: --idle-probe-after must be a non-negative integer" >&2
    exit 2
fi

mapfile -t EXAMPLE_PROJECTS < <(find "$EXAMPLES_DIR" -mindepth 1 -maxdepth 1 -type d | sort)

echo "==> Building ddiscord library"
(
    cd "$ROOT_DIR"
    dub build
)

echo
echo "==> Building example projects"
for project_dir in "${EXAMPLE_PROJECTS[@]}"; do
    if [[ ! -f "$project_dir/dub.json" ]]; then
        continue
    fi

    project_name="$(basename "$project_dir")"
    echo
    echo "---- [build] $project_name ----"
    (
        cd "$project_dir"
        dub build
    )
done

echo
if [[ "${TEST_BOT_SKIP_RUN:-0}" == "1" ]]; then
    echo "---- [skip] test-bot run (TEST_BOT_SKIP_RUN=1) ----"
    exit 0
fi

if [[ -z "${DISCORD_TOKEN:-}" && -z "${TOKEN:-}" && "${TEST_BOT_FORCE_RUN:-0}" != "1" ]]; then
    echo "---- [skip] test-bot run (set DISCORD_TOKEN/TOKEN or TEST_BOT_FORCE_RUN=1) ----"
    exit 0
fi

if [[ "$BOT_SECONDS" == "0" ]]; then
    echo "---- [run] test-bot (continuous; Ctrl+C to stop) ----"
else
    echo "---- [run] test-bot for ${BOT_SECONDS}s (idle probe after ${IDLE_PROBE_AFTER_SECONDS}s) ----"
fi

(
    cd "$EXAMPLES_DIR/test-bot"
    TEST_BOT_RUN_SECONDS="$BOT_SECONDS" \
        TEST_BOT_IDLE_PROBE_AFTER_SECONDS="$IDLE_PROBE_AFTER_SECONDS" \
        dub run
)
