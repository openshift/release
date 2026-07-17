#!/bin/bash

set -euo pipefail

source "${SHARED_DIR}/telco-kpis-common-functions.sh"

export_env_vars_from_json 'mirror_spoke_operators' "${INFRA_SETTINGS:-}" "${INFRA_SETTINGS_DEFAULTS:-}"

main() {
    echo "Mirroring spoke operators to hub: ${HUB_CLUSTER}"

    setup_ansible_inventory "${SPOKE_CLUSTER:-dummy-spoke}" "${HUB_CLUSTER}"

    cd /eco-ci-cd

    local kubeconfig="/home/telcov10n/project/generated/${HUB_CLUSTER}/auth/kubeconfig"

    DEBUG_FLAG="-vv"
    if [ "${DEBUG}" = "true" ]; then
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
    else
        extra_vars+=(-e "version=${VERSION}")
    fi

    if [[ "${GENERATE_SPOKE_LOCKDOWN:-false}" == "true" ]]; then
        echo "Spoke lockdown generation enabled"
        extra_vars+=(-e "generate_spoke_lockdown=true")
        extra_vars+=(-e "hub_name=${HUB_CLUSTER}")
        extra_vars+=(-e "architecture=${ARCHITECTURE:-x86_64}")
    fi

    ansible-playbook ./playbooks/telco-kpis/mirror-spoke-operators.yml \
        -i ./inventories/ocp-deployment/build-inventory.py \
        "${extra_vars[@]}" \
        ${DEBUG_FLAG}

    echo "Spoke operator mirroring completed: ${HUB_CLUSTER}"
}

main
