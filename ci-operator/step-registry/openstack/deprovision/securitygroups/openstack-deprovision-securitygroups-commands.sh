#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

export OS_CLIENT_CONFIG_FILE=${SHARED_DIR}/clouds.yaml
if [[ -f "${SHARED_DIR}/ADDITIONALSECURITYGROUPIDS" ]]; then
    for ID in $(cat ${SHARED_DIR}/ADDITIONALSECURITYGROUPIDS); do
        openstack security group delete ${ID}  || true
    done
fi
