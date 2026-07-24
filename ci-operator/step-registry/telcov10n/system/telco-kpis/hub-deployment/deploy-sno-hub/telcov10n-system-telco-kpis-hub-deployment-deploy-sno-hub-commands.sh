#!/bin/bash

set -euo pipefail

source "${SHARED_DIR}/telco-kpis-common-functions.sh"

export_env_vars_from_json 'deploy_sno_hub' "${INFRA_SETTINGS:-}" "${INFRA_SETTINGS_DEFAULTS:-}"
setup_debug_on_fail

main() {
    echo "Deploying SNO hub cluster: ${HUB_CLUSTER}"

    # Hub IS the OCP cluster being deployed — pass as both spoke and hub args
    setup_ansible_inventory "${HUB_CLUSTER}" "${HUB_CLUSTER}"

    cd /eco-ci-cd

    DEBUG_FLAG="-vv"
    if [ "${DEBUG}" = "true" ]; then
        DEBUG_FLAG="-vvv"
    fi

    # Pass release sources to wrapper playbook for resolution
    # Precedence: lockdown_uri > raw_ocp_release_image > raw_release
    local extra_vars=(
        -e "cluster_name=${HUB_CLUSTER}"
        -e "disconnected=true"
        -e "raw_release=${VERSION}"
    )

    if [[ -n "${HUB_LOCKDOWN_URI:-}" ]]; then
        echo "Lockdown URI provided for OCP release resolution: ${HUB_LOCKDOWN_URI}"
        extra_vars+=(-e "lockdown_uri=${HUB_LOCKDOWN_URI}")
    fi

    if [[ -n "${OCP_RELEASE_IMAGE:-}" ]]; then
        extra_vars+=(-e "raw_ocp_release_image=${OCP_RELEASE_IMAGE}")
    fi

    ansible-playbook ./playbooks/telco-kpis/deploy-ocp-sno.yml \
        -i ./inventories/ocp-deployment/build-inventory.py \
        "${extra_vars[@]}" \
        ${DEBUG_FLAG}

    echo "SNO hub deployment completed: ${HUB_CLUSTER}"
}

main
