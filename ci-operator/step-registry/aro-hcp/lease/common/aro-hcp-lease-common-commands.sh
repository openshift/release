#!/bin/bash

function aro_hcp_lease::env_file() {
    if [[ -z "${SHARED_DIR:-}" ]]; then
        printf '$SHARED_DIR is empty\n' >&2
        return 1
    fi

    printf '%s/aro-hcp-slot-env.sh' "$SHARED_DIR"
}

function aro_hcp_lease::source_env_exports() {
    local env_file
    env_file=$(aro_hcp_lease::env_file) || return 1

    if [[ ! -f "$env_file" ]]; then
        printf 'Missing runtime lease export file: %s\n' "$env_file" >&2
        return 1
    fi

    # shellcheck disable=SC1090
    source "$env_file"
}
