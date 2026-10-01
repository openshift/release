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
        # Variable renamed with telco_kpis_ prefix to avoid upstream clashing
        extra_vars+=(-e "telco_kpis_spoke_lockdown_uri=${SPOKE_LOCKDOWN_URI}")
        # version is intentionally omitted: wrapper extracts spoke_ocp_version from lockdown
        echo "Wrapper will extract operators, version, architecture from lockdown JSON"
    else
        # Variable renamed with telco_kpis_ prefix for wrapper
        extra_vars+=(-e "telco_kpis_version=${VERSION}")
        echo "Wrapper will use version from parameter"
    fi

    if [[ "${GENERATE_SPOKE_LOCKDOWN:-false}" == "true" ]]; then
        echo "Spoke lockdown generation enabled"
        local timestamp
        timestamp=$(date -u +%Y%m%d_%H%M%S)
        local lockdown_filename="lockdown-spoke-${VERSION:-unknown}-${ARCHITECTURE:-x86_64}-${timestamp}-${BUILD_ID:-0}-prow.json"
        # All variables prefixed with telco_kpis_ to avoid upstream clashing
        # Write to /tmp on the bastion (tasks run via SSH there, not inside the container).
        extra_vars+=(-e "telco_kpis_lockdown_output_file=/tmp/${lockdown_filename}")
        extra_vars+=(-e "telco_kpis_hub_name=${HUB_CLUSTER}")
        extra_vars+=(-e "telco_kpis_build_number=${BUILD_ID:-0}")
        extra_vars+=(-e "telco_kpis_generate_lockdown=true")
        # In lockdown-validation mode (SPOKE_LOCKDOWN_URI set) architecture is extracted
        # from the lockdown JSON by wrapper — do not override it here.
        if [[ -z "${SPOKE_LOCKDOWN_URI:-}" ]]; then
            extra_vars+=(-e "telco_kpis_architecture=${ARCHITECTURE:-x86_64}")
        fi
    fi

    ansible-playbook ./playbooks/telco-kpis/mirror-spoke-operators.yml \
        -i ./inventories/ocp-deployment/build-inventory.py \
        "${extra_vars[@]}" \
        ${DEBUG_FLAG}

    echo "Spoke operator mirroring completed: ${HUB_CLUSTER}"
}

main
