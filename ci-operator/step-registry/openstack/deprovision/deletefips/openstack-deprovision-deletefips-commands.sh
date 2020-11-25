#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

echo using ${OS_CLOUD}
export OS_CLIENT_CONFIG_FILE=${CLUSTER_PROFILE_DIR}/clouds.yaml

if [[ -f "${SHARED_DIR}/DELETE_FIPS" ]]; then
    for FIP in $(cat ${SHARED_DIR}/DELETE_FIPS); do
        openstack floating ip delete ${FIP}  || true
    done
fi
