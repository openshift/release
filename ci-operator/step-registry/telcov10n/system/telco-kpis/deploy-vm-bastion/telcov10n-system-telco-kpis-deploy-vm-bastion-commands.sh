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

    LOCK_NAME="vm_bastion_deploy"
    UUID_FILE="/tmp/remote_flock_${LOCK_NAME}.uuid"
    LOCK_UUID=""

    release_lock() {
        if [ -n "${LOCK_UUID}" ]; then
            echo "Releasing lock '${LOCK_NAME}' (UUID=${LOCK_UUID}, BUILD_ID=${BUILD_ID:-unknown})..."
            ansible-playbook ./playbooks/telco-kpis/remote-flock-release.yml \
                -i ./inventories/infra/deploy-vm-bastion-libvirt.yml \
                -e remote_flock_name="${LOCK_NAME}" \
                -e remote_flock_uuid="${LOCK_UUID}" \
                -e remote_flock_become=true \
                ${DEBUG_FLAG} || echo "WARNING: Failed to release lock '${LOCK_NAME}'"
            LOCK_UUID=""
            rm -f "${UUID_FILE}"
        fi
    }
    trap release_lock EXIT

    echo "Acquiring lock '${LOCK_NAME}' on hypervisor (BUILD_ID=${BUILD_ID:-unknown})..."
    ansible-playbook ./playbooks/telco-kpis/remote-flock-acquire.yml \
        -i ./inventories/infra/deploy-vm-bastion-libvirt.yml \
        -e remote_flock_name="${LOCK_NAME}" \
        -e remote_flock_uuid_file="${UUID_FILE}" \
        -e remote_flock_become=true \
        ${DEBUG_FLAG}

    LOCK_UUID=$(cat "${UUID_FILE}")
    echo "Lock acquired: UUID=${LOCK_UUID}, BUILD_ID=${BUILD_ID:-unknown}"

    ansible-playbook ./playbooks/infra/deploy-vm-bastion-libvirt.yml \
        -i ./inventories/infra/deploy-vm-bastion-libvirt.yml \
        -e location="${LOCATION}" \
        ${DEBUG_FLAG}

    echo "Bastion VM deployment completed: ${MACHINE}"
}

main
