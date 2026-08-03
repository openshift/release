#!/bin/bash

set -euo pipefail

source "${SHARED_DIR}/telco-kpis-common-functions.sh"

export_env_vars_from_json 'install_hub_operators' "${INFRA_SETTINGS:-}" "${INFRA_SETTINGS_DEFAULTS:-}"
setup_debug_on_fail

main() {
    echo "Installing hub operators on: ${HUB_CLUSTER}"

    setup_ansible_inventory "${HUB_CLUSTER}" "${HUB_CLUSTER}"

    cd /eco-ci-cd

    local kubeconfig="/home/telcov10n/project/generated/${HUB_CLUSTER}/auth/kubeconfig"

    DEBUG_FLAG="-vv"
    if [ "${DEBUG}" = "true" ]; then
        DEBUG_FLAG="-vvv"
    fi

    local extra_vars=(
        -e "kubeconfig=${kubeconfig}"
        -e "version=${VERSION}"
        -e "disconnected=true"
        -e "mirror_only=false"
        -e "ocp_operator_mirror_skip_internal_registry_cleanup=true"
    )

    if [[ -n "${HUB_LOCKDOWN_URI:-}" ]]; then
        echo "Using hub lockdown: ${HUB_LOCKDOWN_URI}"
        extra_vars+=(-e "hub_lockdown_uri=${HUB_LOCKDOWN_URI}")
    fi

    if [[ "${GENERATE_HUB_LOCKDOWN:-false}" == "true" ]]; then
        echo "Hub lockdown generation enabled"
        extra_vars+=(-e "generate_hub_lockdown=true")
        extra_vars+=(-e "hub_cluster=${HUB_CLUSTER}")
        extra_vars+=(-e "architecture=${ARCHITECTURE:-x86_64}")
    fi

    ansible-playbook ./playbooks/telco-kpis/deploy-ocp-operators.yml \
        -i ./inventories/ocp-deployment/build-inventory.py \
        "${extra_vars[@]}" \
        ${DEBUG_FLAG}

    echo "Hub operator installation completed: ${HUB_CLUSTER}"
}

main
