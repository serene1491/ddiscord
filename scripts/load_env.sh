#!/usr/bin/env bash

# Shared env loader for repository scripts.
# Loads .env files from script-local and examples directories when present,
# exporting variables for child commands.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
EXAMPLES_DIR="$ROOT_DIR/examples"

load_script_env() {
    local env_file
    for env_file in \
        "$SCRIPT_DIR/.env" \
        "$SCRIPT_DIR/.env.local" \
        "$EXAMPLES_DIR/.env" \
        "$EXAMPLES_DIR/.env.local"
    do
        if [[ -f "$env_file" ]]; then
            set -a
            # shellcheck disable=SC1090
            source "$env_file"
            set +a
        fi
    done
}
