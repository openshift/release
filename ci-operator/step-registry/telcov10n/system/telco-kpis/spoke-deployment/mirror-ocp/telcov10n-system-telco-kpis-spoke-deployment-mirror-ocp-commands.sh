#!/bin/bash

set -euo pipefail

source "${SHARED_DIR}/telco-kpis-common-functions.sh"

export_env_vars_from_json 'mirror_ocp' "${INFRA_SETTINGS:-}" "${INFRA_SETTINGS_DEFAULTS:-}"
setup_debug_on_fail

main() {
    echo "Mirroring OCP release image to hub: ${HUB_CLUSTER}"

    setup_ansible_inventory "${SPOKE_CLUSTER:-dummy-spoke}" "${HUB_CLUSTER}"

    if [[ -n "${LOCKDOWN_URI:-}" ]]; then
        resolve_ocp_version_from_lockdown "${LOCKDOWN_URI}"
    fi

    cd /eco-ci-cd

    local kubeconfig="/home/telcov10n/project/generated/${HUB_CLUSTER}/auth/kubeconfig"

    local DEBUG_FLAG="-vv"
    if [[ "${DEBUG:-false}" == "true" ]]; then
        DEBUG_FLAG="-vvv"
    fi

    local extra_vars=(
        -e "kubeconfig=${kubeconfig}"
        -e "ocp_version=${VERSION}"
    )

    if [[ -n "${OCP_RELEASE_IMAGE:-}" ]]; then
        if [[ "${OCP_RELEASE_IMAGE}" != *"@sha256:"* ]]; then
            echo "OCP_RELEASE_IMAGE is tag-based -- playbook will resolve to digest format"
        fi
        extra_vars+=(-e "raw_ocp_release_image=${OCP_RELEASE_IMAGE}")
    fi

    if [[ -n "${LOCKDOWN_URI:-}" ]]; then
        echo "Lockdown URI provided for OCP release image resolution: ${LOCKDOWN_URI}"
        extra_vars+=(-e "lockdown_uri=${LOCKDOWN_URI}")
    fi

    if [[ -z "${OCP_RELEASE_IMAGE:-}" ]] && [[ -z "${LOCKDOWN_URI:-}" ]]; then
        echo "No explicit image or lockdown -- will mirror hub cluster's own release image"
    fi

    ansible-playbook ./playbooks/telco-kpis/mirror-ocp.yml \
        -i ./inventories/ocp-deployment/build-inventory.py \
        "${extra_vars[@]}" \
        ${DEBUG_FLAG}

    echo "OCP release image mirroring completed: ${HUB_CLUSTER}"
}

main
