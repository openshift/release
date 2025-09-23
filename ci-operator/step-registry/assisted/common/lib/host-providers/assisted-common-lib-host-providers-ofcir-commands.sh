#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/host-contract/assisted-common-lib-host-contract-commands.sh"

host_provider_ofcir::_find_ofcir_script() {
    local script_name="$1"

    # Try step registry path first
    local step_registry_base="${STEP_REGISTRY_PATH:-}"
    if [[ -n "$step_registry_base" && -f "${step_registry_base}/ofcir/${script_name}" ]]; then
        printf '%s\n' "${step_registry_base}/ofcir/${script_name}"
        return 0
    fi

    # Fallback to relative path from current script location
    local rel_path="${SCRIPT_DIR}/../../../../../../../ofcir/${script_name}"
    if [[ -f "$rel_path" ]]; then
        printf '%s\n' "$rel_path"
        return 0
    fi

    echo "OFCIR script not found: $script_name" >&2
    return 1
}

host_provider_ofcir::acquire() {
    echo "[host-provider/ofcir] Acquiring host via upstream ofcir-acquire"

    # Find and execute the real ofcir-acquire script
    local ofcir_acquire_script
    ofcir_acquire_script="$(host_provider_ofcir::_find_ofcir_script 'acquire/ofcir-acquire-commands.sh')" || return 1

    if ! bash "$ofcir_acquire_script"; then
        echo "[host-provider/ofcir] Upstream ofcir-acquire failed" >&2
        return 1
    fi

    # ofcir-acquire creates packet-conf.sh, server-ip, and other files
    # Read them and translate to host contract format

    # Source packet-conf.sh to get IP and SSH options
    if [[ ! -f "${SHARED_DIR}/packet-conf.sh" ]]; then
        echo "[host-provider/ofcir] Expected packet-conf.sh not found after ofcir-acquire" >&2
        return 1
    fi

    # shellcheck disable=SC1091
    source "${SHARED_DIR}/packet-conf.sh"

    local ip="${IP:-}"
    if [[ -z "$ip" ]]; then
        echo "[host-provider/ofcir] IP not found in packet-conf.sh" >&2
        return 1
    fi

    # Extract port from SSHOPTS or default to 22
    local port="22"
    if [[ -f "${SHARED_DIR}/server-sshport" ]]; then
        port="$(<"${SHARED_DIR}/server-sshport")"
    fi

    local key_path="${CLUSTER_PROFILE_DIR}/packet-ssh-key"
    local cir_file="${SHARED_DIR}/cir"

    # Write host contract
    host_contract::writer::begin
    host_contract::writer::set HOST_PROVIDER "ofcir"
    host_contract::writer::set HOST_PRIMARY_IP "$ip"
    host_contract::writer::set HOST_PRIMARY_SSH_USER "root"
    host_contract::writer::set HOST_PRIMARY_SSH_PORT "$port"
    host_contract::writer::set HOST_PRIMARY_SSH_KEY_PATH "$key_path"
    if [[ -f "$cir_file" ]]; then
        host_contract::writer::set HOST_PRIMARY_METADATA_PATH "$cir_file"
    fi
    host_contract::writer::set HOST_PRIMARY_SSH_ADDITIONAL_OPTIONS "-o Port=$port -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=90 -o LogLevel=ERROR -i $key_path"
    host_contract::writer::commit

    echo "[host-provider/ofcir] Host contract written, IP: $ip, Port: $port"
    return 0
}

host_provider_ofcir::release() {
    echo "[host-provider/ofcir] Releasing host via upstream ofcir-release"

    # Find and execute the real ofcir-release script
    local ofcir_release_script
    ofcir_release_script="$(host_provider_ofcir::_find_ofcir_script 'release/ofcir-release-commands.sh')"

    if [[ -n "$ofcir_release_script" && -f "$ofcir_release_script" ]]; then
        bash "$ofcir_release_script"
    else
        echo "[host-provider/ofcir] Warning: ofcir-release script not found, skipping release"
    fi
}

host_provider_ofcir::gather() {
    echo "[host-provider/ofcir] Gathering artifacts via upstream ofcir-gather"

    # Find and execute the real ofcir-gather script
    local ofcir_gather_script
    ofcir_gather_script="$(host_provider_ofcir::_find_ofcir_script 'gather/ofcir-gather-commands.sh')"

    if [[ -n "$ofcir_gather_script" && -f "$ofcir_gather_script" ]]; then
        bash "$ofcir_gather_script"
    else
        echo "[host-provider/ofcir] Warning: ofcir-gather script not found, skipping gather"
    fi
}

