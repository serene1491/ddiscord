#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXAMPLES_DIR="$ROOT_DIR/examples"
DEFAULT_BOT_SECONDS="${TEST_BOT_RUN_SECONDS:-45}"
BOT_SECONDS="$DEFAULT_BOT_SECONDS"

if [[ "${1:-}" == "--bot-seconds" ]]; then
    if [[ -z "${2:-}" ]]; then
        echo "error: missing value for --bot-seconds" >&2
        exit 2
    fi
    BOT_SECONDS="$2"
    shift 2
fi

if [[ $# -gt 0 ]]; then
    echo "error: unsupported arguments: $*" >&2
    echo "usage: $0 [--bot-seconds <seconds>]" >&2
    exit 2
fi

if ! [[ "$BOT_SECONDS" =~ ^[0-9]+$ ]]; then
    echo "error: --bot-seconds must be a non-negative integer" >&2
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
if [[ "$BOT_SECONDS" == "0" ]]; then
    echo "---- [run] test-bot (continuous; Ctrl+C to stop) ----"
else
    echo "---- [run] test-bot for ${BOT_SECONDS}s ----"
fi

(
    cd "$EXAMPLES_DIR/test-bot"
    TEST_BOT_RUN_SECONDS="$BOT_SECONDS" dub run
)
