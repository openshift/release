#!/bin/bash

set -euo pipefail

source "${SHARED_DIR}/telco-kpis-common-functions.sh"

export_env_vars_from_json 'deploy_vm_bastion' "${INFRA_SETTINGS:-}" "${INFRA_SETTINGS_DEFAULTS:-}"
setup_debug_on_fail

main() {
    MACHINE="bastion.${HUB_CLUSTER}.telco-kpis.rdu3.redhat.com"
    echo "Deploying bastion VM: ${MACHINE}"

    setup_infra_inventory "${HUB_CLUSTER}"

    cd /eco-ci-cd

    DEBUG_FLAG="-vv"
    if [ "${DEBUG}" = "true" ]; then
        DEBUG_FLAG="-vvv"
    fi

    ansible-playbook ./playbooks/infra/deploy-vm-bastion-libvirt.yml \
        -i ./inventories/infra/deploy-vm-bastion-libvirt.yml \
        -e location="${LOCATION}" \
        ${DEBUG_FLAG}

    echo "Bastion VM deployment completed: ${MACHINE}"
}

main
