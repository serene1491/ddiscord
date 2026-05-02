#!/usr/bin/env bash

# Shared env loader for repository scripts.
# Loads scripts/.env and scripts/.env.local when present, exporting variables.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

load_script_env() {
    local env_file
    for env_file in "$SCRIPT_DIR/.env" "$SCRIPT_DIR/.env.local"; do
        if [[ -f "$env_file" ]]; then
            set -a
            # shellcheck disable=SC1090
            source "$env_file"
            set +a
        fi
    done
}
