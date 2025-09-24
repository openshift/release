#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/host-contract/host-contract.sh"

host_provider_ofcir::_resolve_step_registry_path() {
    local rel="$1"
    local base="${STEP_REGISTRY_PATH:-}"
    if [[ -n "$base" && -d "$base" && -f "${base}/ofcir/${rel}" ]]; then
        printf '%s\n' "${base}/ofcir/${rel}"
        return 0
    fi

    local fallback="${SCRIPT_DIR}/../../../../../../ofcir/${rel}"
    if [[ -f "$fallback" ]]; then
        printf '%s\n' "$fallback"
        return 0
    fi

    echo "[host-provider/ofcir] upstream script not found: ${rel}" >&2
    return 1
}

host_provider_ofcir::acquire() {
    local upstream
    upstream="$(host_provider_ofcir::_resolve_step_registry_path 'acquire/ofcir-acquire-commands.sh')" || return 1

    echo "[host-provider/ofcir] executing upstream acquire: ${upstream}"
    if ! bash "$upstream"; then
        echo "[host-provider/ofcir] upstream acquire failed" >&2
        return 1
    fi

    local ip_file="$SHARED_DIR/server-ip"
    local port_file="$SHARED_DIR/server-sshport"
    local cir_file="$SHARED_DIR/cir"
    local key_path="${CLUSTER_PROFILE_DIR}/packet-ssh-key"

    if [[ ! -s "$ip_file" ]]; then
        echo "[host-provider/ofcir] missing server-ip after upstream acquire" >&2
        return 1
    fi

    local ip
    ip=$(<"$ip_file")
    local port=22
    if [[ -s "$port_file" ]]; then
        port=$(<"$port_file")
    fi

    host_contract::writer::begin
    host_contract::writer::set HOST_PROVIDER "ofcir"
    host_contract::writer::set HOST_PRIMARY_IP "$ip"
    host_contract::writer::set HOST_PRIMARY_SSH_USER "root"
    host_contract::writer::set HOST_PRIMARY_SSH_PORT "$port"
    host_contract::writer::set HOST_PRIMARY_SSH_KEY_PATH "$key_path"
    host_contract::writer::set HOST_PRIMARY_METADATA_PATH "$cir_file"
    host_contract::writer::set HOST_PRIMARY_SSH_ADDITIONAL_OPTIONS "-p ${port} -i ${key_path} -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=90 -o LogLevel=ERROR"
    host_contract::writer::commit

    return 0
}

host_provider_ofcir::release() {
    local upstream
    upstream="$(host_provider_ofcir::_resolve_step_registry_path 'release/ofcir-release-commands.sh')" || return 1

    echo "[host-provider/ofcir] executing upstream release: ${upstream}"
    bash "$upstream"
}

host_provider_ofcir::gather() {
    local helper="${SCRIPT_DIR}/ofcir-gather.sh"
    if [[ ! -f "$helper" ]]; then
        echo "[host-provider/ofcir] gather helper not found: ${helper}" >&2
        return 1
    fi
    bash "$helper"
}
