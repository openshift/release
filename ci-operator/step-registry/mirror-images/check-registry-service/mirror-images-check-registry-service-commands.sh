#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

set -x

if [[ ! -e "${SHARED_DIR}/bastion_public_address" ]]; then
    echo "bastion public address do not exist, skip this step."
    exit 0
fi


BASTION_PUBLIC_ADDRESS="$(< "${SHARED_DIR}/bastion_public_address")"
SSH_PRIV_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-privatekey
BASTION_SSH_USER="$(< "${SHARED_DIR}/bastion_ssh_user" )"


function check_mirror_registry_response()
{
    local try=0
    local max_retries=20
    local interval=30

    while (( try < max_retries )); do
        echo "Checking mirror registry response code ${try}/${max_retries}"
        http_code=$(curl -o /dev/null -I -k -s -w "%{http_code}" "https://${BASTION_PUBLIC_ADDRESS}:5000" || true)
        if [[ "${http_code}" != "200" ]]; then
            echo "curl http return code: ${http_code}"
            sleep ${interval}
        else
            echo "Succeed."
            return 0
        fi
        (( try += 1 ))
    done
    return 1
}


function check_mirror_registry_service_status()
{
    local try=0
    local max_retries=20
    local interval=30

    while (( try < max_retries )); do
        echo "Checking mirror registry service status ${try}/${max_retries}"
        
        
        ssh -o UserKnownHostsFile=/dev/null -o IdentityFile="${SSH_PRIV_KEY_PATH}" -o StrictHostKeyChecking=no \
            ${BASTION_SSH_USER}@"${BASTION_PUBLIC_ADDRESS}" \
            "sudo systemctl status poc-registry-5000.service" > "${ARTIFACT_DIR}/poc-registry-5000.status"
        
        echo "Debug: content of ${ARTIFACT_DIR}/poc-registry-5000.status"
        cat ${ARTIFACT_DIR}/poc-registry-5000.status

        if ! grep "Active: active (running) since" "${ARTIFACT_DIR}/poc-registry-5000.status"; then
            sleep ${interval}
        else
            echo "Succeed."
            return 0
        fi
        (( try += 1 ))
    done
    return 1
}

check_mirror_registry_response
check_mirror_registry_service_status
