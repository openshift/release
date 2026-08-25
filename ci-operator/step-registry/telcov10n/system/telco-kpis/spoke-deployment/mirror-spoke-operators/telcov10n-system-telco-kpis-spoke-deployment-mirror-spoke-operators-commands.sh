#!/bin/bash

set -euo pipefail

source "${SHARED_DIR}/telco-kpis-common-functions.sh"

export_env_vars_from_json 'mirror_spoke_operators' "${INFRA_SETTINGS:-}" "${INFRA_SETTINGS_DEFAULTS:-}"
setup_debug_on_fail

main() {
    echo "Mirroring spoke operators to hub: ${HUB_CLUSTER}"

    setup_ansible_inventory "${SPOKE_CLUSTER:-dummy-spoke}" "${HUB_CLUSTER}"

    cd /eco-ci-cd

    local kubeconfig="/home/telcov10n/project/generated/${HUB_CLUSTER}/auth/kubeconfig"

    local DEBUG_FLAG="-vv"
    if [[ "${DEBUG:-false}" == "true" ]]; then
        DEBUG_FLAG="-vvv"
    fi

    local extra_vars=(
        -e "kubeconfig=${kubeconfig}"
        -e "disconnected=true"
        -e "mirror_only=true"
        -e "ocp_operator_mirror_skip_internal_registry_cleanup=true"
        -e "ocp_operator_mirror_skip_manifest_apply=true"
    )

    if [[ -n "${SPOKE_LOCKDOWN_URI:-}" ]]; then
        echo "Using spoke lockdown: ${SPOKE_LOCKDOWN_URI}"
        extra_vars+=(-e "spoke_lockdown_uri=${SPOKE_LOCKDOWN_URI}")
        # version is intentionally omitted in lockdown mode: mirror-spoke-operators.yml
        # extracts spoke_ocp_version from the lockdown and overwrites the version fact,
        # so passing it here would be redundant and could mask lockdown mismatches.
    else
        extra_vars+=(-e "version=${VERSION}")
    fi

    if [[ "${GENERATE_SPOKE_LOCKDOWN:-false}" == "true" ]]; then
        echo "Spoke lockdown generation enabled"
        local timestamp
        timestamp=$(date -u +%Y%m%d_%H%M%S)
        local lockdown_filename="lockdown-spoke-${VERSION:-unknown}-${ARCHITECTURE:-x86_64}-${timestamp}-${BUILD_ID:-0}-prow.json"
        # lockdown_output_file is what the playbook checks to trigger generation:
        #   ocp_operator_mirror_generate_lockdown: "{{ (lockdown_output_file | default('') | length > 0) }}"
        # Write to /tmp on the bastion (tasks run via SSH there, not inside the container).
        extra_vars+=(-e "lockdown_output_file=/tmp/${lockdown_filename}")
        extra_vars+=(-e "hub_name=${HUB_CLUSTER}")
        # Prow exposes BUILD_ID; use it as build_number for lockdown metadata.
        extra_vars+=(-e "build_number=${BUILD_ID:-0}")
        # In lockdown-validation mode (SPOKE_LOCKDOWN_URI set) architecture is extracted
        # from the lockdown JSON — do not override it here.
        if [[ -z "${SPOKE_LOCKDOWN_URI:-}" ]]; then
            extra_vars+=(-e "architecture=${ARCHITECTURE:-x86_64}")
        fi
    fi

    ansible-playbook ./playbooks/telco-kpis/mirror-spoke-operators.yml \
        -i ./inventories/ocp-deployment/build-inventory.py \
        "${extra_vars[@]}" \
        ${DEBUG_FLAG}

    echo "Spoke operator mirroring completed: ${HUB_CLUSTER}"
}

main
