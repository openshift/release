#!/bin/bash

function aro_hcp_lease::state_dir() {
    if [[ -z "${SHARED_DIR:-}" ]]; then
        printf '$SHARED_DIR is empty\n' >&2
        return 1
    fi

    printf '%s/aro-hcp-leases' "$SHARED_DIR"
}

function aro_hcp_lease::env_file() {
    local state_dir
    state_dir=$(aro_hcp_lease::state_dir) || return 1
    printf '%s/env.sh' "$state_dir"
}

function aro_hcp_lease::handle_file() {
    local role="$1"
    local state_dir
    state_dir=$(aro_hcp_lease::state_dir) || return 1
    printf '%s/%s.handle' "$state_dir" "$role"
}

function aro_hcp_lease::proxy_available() {
    [[ -n "${LEASE_PROXY_SERVER_URL:-}" ]]
}

function aro_hcp_lease::prepare_state() {
    local state_dir env_file
    state_dir=$(aro_hcp_lease::state_dir) || return 1
    env_file=$(aro_hcp_lease::env_file) || return 1

    rm -rf "$state_dir"
    mkdir -p "$state_dir"
    : > "$env_file"
}

function aro_hcp_lease::persist_temp_handle() {
    local role="$1"
    local temp_handle="$2"
    local handle_file
    handle_file=$(aro_hcp_lease::handle_file "$role") || return 1

    if ! cp "$temp_handle" "$handle_file"; then
        printf 'Failed to persist lease handle for role "%s"\n' "$role" >&2
        lease__release --handle="$temp_handle" || true
        return 1
    fi

    if ! touch "${handle_file}.lock"; then
        printf 'Failed to create lock file for role "%s"\n' "$role" >&2
        rm -f "$handle_file"
        lease__release --handle="$temp_handle" || true
        return 1
    fi

    rm -f "$temp_handle" "${temp_handle}.lock"
}

function aro_hcp_lease::acquire_role() {
    local role="$1"
    local type="$2"
    local count="${3:-1}"
    local temp_handle handle_file

    if ! aro_hcp_lease::proxy_available; then
        printf 'LEASE_PROXY_SERVER_URL not set, skipping acquire for role "%s"\n' "$role"
        return 0
    fi

    temp_handle=$(lease__acquire --type="$type" --count="$count" --scope=step)
    aro_hcp_lease::persist_temp_handle "$role" "$temp_handle"

    handle_file=$(aro_hcp_lease::handle_file "$role") || return 1
    printf 'Acquired role "%s" from "%s": %s\n' \
        "$role" \
        "$type" \
        "$(lease__cat --handle="$handle_file" --format=csv)"
}

function aro_hcp_lease::read_handle_values() {
    local role="$1"
    local handle_file
    handle_file=$(aro_hcp_lease::handle_file "$role") || return 1

    if [[ ! -f "$handle_file" ]]; then
        return 0
    fi

    mapfile -t values < "$handle_file"
    if [[ "${#values[@]}" -eq 0 ]]; then
        return 0
    fi

    local joined="${values[0]}"
    local i
    for ((i = 1; i < ${#values[@]}; i++)); do
        joined+=" ${values[i]}"
    done

    printf '%s' "$joined"
}

function aro_hcp_lease::write_export() {
    local name="$1"
    local value="$2"
    local env_file
    env_file=$(aro_hcp_lease::env_file) || return 1

    printf 'export %s=%q\n' "$name" "$value" >> "$env_file"
}

function aro_hcp_lease::write_env_exports() {
    local env_file
    env_file=$(aro_hcp_lease::env_file) || return 1
    : > "$env_file"

    local value

    value=$(aro_hcp_lease::read_handle_values "env-quota")
    if [[ -n "$value" ]]; then
        aro_hcp_lease::write_export "ENV_QUOTA_LEASED_RESOURCE" "$value"
    fi

    value=$(aro_hcp_lease::read_handle_values "msi-containers")
    if [[ -n "$value" ]]; then
        aro_hcp_lease::write_export "LEASED_MSI_CONTAINERS" "$value"
    fi

    value=$(aro_hcp_lease::read_handle_values "msi-mock-sp")
    if [[ -n "$value" ]]; then
        aro_hcp_lease::write_export "LEASED_MSI_MOCK_SP" "$value"
    fi
}

function aro_hcp_lease::source_env_exports() {
    local env_file
    env_file=$(aro_hcp_lease::env_file) || return 1

    if [[ ! -f "$env_file" ]]; then
        return 0
    fi

    # shellcheck disable=SC1090
    source "$env_file"
}

function aro_hcp_lease::release_all() {
    local state_dir
    state_dir=$(aro_hcp_lease::state_dir) || return 1

    if [[ ! -d "$state_dir" ]]; then
        return 0
    fi

    local result=0
    local handle_file
    shopt -s nullglob
    for handle_file in "$state_dir"/*.handle; do
        lease__release --handle="$handle_file" || result=$?
    done
    shopt -u nullglob

    if [[ "$result" -eq 0 ]]; then
        rm -rf "$state_dir"
    fi

    return "$result"
}
