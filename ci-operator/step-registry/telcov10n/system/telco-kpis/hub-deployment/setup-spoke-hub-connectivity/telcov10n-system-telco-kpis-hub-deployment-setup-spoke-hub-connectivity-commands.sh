#!/bin/bash

set -euo pipefail

source "${SHARED_DIR}/telco-kpis-common-functions.sh"

export_env_vars_from_json 'setup_spoke_hub_connectivity' "${INFRA_SETTINGS:-}" "${INFRA_SETTINGS_DEFAULTS:-}"

main() {
    echo "Setting up spoke-hub connectivity: ${SPOKE_CLUSTER} -> ${HUB_CLUSTER}"

    setup_ansible_inventory "${SPOKE_CLUSTER}" "${HUB_CLUSTER}"

    cd /eco-ci-cd

    local hub_kubeconfig="/home/telcov10n/project/generated/${HUB_CLUSTER}/auth/kubeconfig"

    DEBUG_FLAG="-vv"
    if [ "${DEBUG}" = "true" ]; then
        DEBUG_FLAG="-vvv"
    fi

    ansible-playbook ./playbooks/telco-kpis/setup-spoke-hub-connectivity.yml \
        -i ./inventories/ocp-deployment/build-inventory.py \
        -e "spoke_name=${SPOKE_CLUSTER}" \
        -e "hub_name=${HUB_CLUSTER}" \
        -e "hypervisor=hypervisor" \
        -e "hub_kubeconfig=${hub_kubeconfig}" \
        -e "action=${ACTION}" \
        -e "update_dns=${UPDATE_DNS}" \
        -e "update_provisioning_cr=${UPDATE_PROVISIONING_CR}" \
        ${DEBUG_FLAG}

    echo "Spoke-hub connectivity ${ACTION} completed: ${SPOKE_CLUSTER} -> ${HUB_CLUSTER}"
}

main
